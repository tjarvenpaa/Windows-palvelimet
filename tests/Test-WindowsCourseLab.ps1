$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'New-WindowsCourseLab.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptFile, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Skriptin jasennys epaonnistui: $errors" }
foreach ($name in @('ConvertTo-IPv4Number', 'ConvertFrom-IPv4Number', 'Get-NetworkRange',
        'Test-PrefixConflict', 'Get-IPv4Addresses', 'ConvertTo-SubnetMask',
        'Test-LabResourceConflicts', 'Assert-LabFilePathsAvailable', 'New-HyperVAnswerIso',
        'Select-AdoptedVMs', 'Remove-Lab')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $definition) { throw "Funktio puuttuu: $name" }
    Invoke-Expression $definition.Extent.Text
}

$script:HyperVSwitch = 'WindowsCourseLab-Internal'
$script:HyperVNat = 'WindowsCourseLab-NAT'
$script:VBoxNat = 'WindowsCourseLab-NAT'
$script:LabRoot = 'E:\TestLab'
$script:mockIps = @()
$script:mockVms = @()
$script:mockFiles = @()
$script:mockVBoxVms = ''
$script:mockVBoxNats = ''
$script:mockVBoxError = 0
$script:questions = 0
$script:answer = ''
$script:mockNat = $null
$script:mockSwitch = $null
$script:mockAttached = @()
$script:removed = @()
$script:manifestJson = ''
$script:ManifestPath = 'E:\TestLab\lab.json'

function Get-NetAdapter { param($Name, $ErrorAction) [pscustomobject]@{ ifIndex = 42 } }
function Get-NetIPAddress { param($AddressFamily, $ErrorAction) return $script:mockIps }
function Get-VM {
    param($Name, $Id, $ErrorAction)
    if ($Id) { return @($script:mockVms | Where-Object Id -eq $Id) }
    if (-not $Name) { return $script:mockVms }
    return @($script:mockVms | Where-Object Name -eq $Name)
}
function Get-NetNat { param($Name, $ErrorAction) if ($null -ne $script:mockNat) { return $script:mockNat } }
function Get-VMSwitch { param($Name, $ErrorAction) if ($null -ne $script:mockSwitch) { return $script:mockSwitch } }
function Get-VMNetworkAdapter { param($VM, $ErrorAction) return $script:mockAttached }
function Get-VBoxManage { return 'Invoke-MockVBox' }
function Invoke-MockVBox {
    $global:LASTEXITCODE = $script:mockVBoxError
    if ($args[1] -eq 'vms') { return $script:mockVBoxVms }
    if ($args[1] -eq 'natnets') { return $script:mockVBoxNats }
}
function Test-Path { param($LiteralPath, $PathType) return $true }
function Get-ChildItem { param($LiteralPath, [switch]$Force, $ErrorAction) return $script:mockFiles }
function Read-Host { param($Prompt) $script:questions++; return $script:answer }
function New-Item { param($ItemType, $Path, [switch]$Force) }
function Set-Content { param($LiteralPath, $Value, $Encoding) $script:answerXml = $Value }
function Remove-Item { param($LiteralPath, [switch]$Recurse, [switch]$Force) $script:removed += $LiteralPath }
function Set-PrivateAcl { param($Path) }
function Invoke-MockOscdimg { $global:LASTEXITCODE = 0; 'oscdimg output'; 'finished' }
function Test-IsAdministrator { return $true }
function Confirm-Change { param($Message) return $true }
function Get-Content { param($LiteralPath, [switch]$Raw) return $script:manifestJson }
function Remove-NetNat { [CmdletBinding(SupportsShouldProcess)] param([Parameter(ValueFromPipeline)]$InputObject) process { $script:removed += 'nat' } }
function Remove-VMSwitch { [CmdletBinding(SupportsShouldProcess)] param([Parameter(ValueFromPipeline)]$InputObject, [switch]$Force) process { $script:removed += 'switch' } }
function Assert-Throws {
    param([scriptblock]$Action, [string]$Expected)
    $caught = $false
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notlike "*$Expected*") { throw }
        $caught = $true
    }
    if (-not $caught) { throw "Odotettu virhe puuttui: $Expected" }
}

$network = Get-IPv4Addresses '192.168.252.50/24'
if ($network.Prefix -ne '192.168.252.0/24' -or $network.Gateway -ne '192.168.252.1' -or
    $network.Guests[2] -ne '192.168.252.12') { throw 'Verkkolaskenta epaonnistui.' }
$script:mockIps = @([pscustomobject]@{ IPAddress = '192.168.252.1'; PrefixLength = 24; InterfaceIndex = 42; PrefixOrigin = 'Manual' })
if (Test-PrefixConflict -Prefix $network.Prefix -Platform 'Hyper-V') { throw 'Olemassa oleva lab-yhdyskaytava tulkittiin ristiriidaksi.' }
if (-not (Test-PrefixConflict -Prefix $network.Prefix -Platform 'VirtualBox')) { throw 'Toisen alustan verkkoristiriitaa ei havaittu.' }
$script:mockIps += [pscustomobject]@{ IPAddress = '192.168.252.5'; PrefixLength = 24; InterfaceIndex = 5; PrefixOrigin = 'Manual' }
if (-not (Test-PrefixConflict -Prefix $network.Prefix -Platform 'Hyper-V')) { throw 'Muun sovittimen ristiriitaa ei havaittu.' }

$id = [guid]::NewGuid()
$script:mockVms = @([pscustomobject]@{ Name = 'Course-Server2'; Id = $id })
Assert-Throws { Test-LabResourceConflicts 'Hyper-V' $network.Prefix @{ 'Course-Server1' = @{ Id = $id } } } 'saman lab-roolin'
Test-LabResourceConflicts 'Hyper-V' $network.Prefix @{ 'Course-Server2' = @{ Id = $id } }
$script:mockVBoxVms = '"Course-Server2" {' + $id.ToString() + '}'
Assert-Throws { Test-LabResourceConflicts 'VirtualBox' $network.Prefix @{ 'Course-Server1' = @{ Id = $id } } } 'saman lab-roolin'
Test-LabResourceConflicts 'VirtualBox' $network.Prefix @{ 'Course-Server2' = @{ Id = $id } }
$script:mockVBoxError = 1
Assert-Throws { Test-LabResourceConflicts 'VirtualBox' $network.Prefix @{} } 'VM-listan luku'
$script:mockVBoxError = 0
$script:mockVBoxVms = ''
$script:mockVBoxNats = "Name: OtherNetwork`nNetwork: 192.168.10.0/24`nDHCP Server: Yes`n`nName: SecondNetwork`nNetwork: 192.168.252.0/24`nDHCP Server: No`n"
Assert-Throws { Test-LabResourceConflicts 'VirtualBox' $network.Prefix @{} } 'SecondNetwork'
$script:mockVBoxNats = "Name: OtherNetwork`nNetwork: 192.168.10.0/24`nDHCP Server: Yes`n`nName: SecondNetwork`nNetwork: 192.168.11.0/24`nDHCP Server: No`n"
Test-LabResourceConflicts 'VirtualBox' $network.Prefix @{}

$script:mockFiles = @([pscustomobject]@{ Name = 'Course-Server1-answer.iso' })
Assert-Throws { Assert-LabFilePathsAvailable @{} } 'ei korvata'
Assert-LabFilePathsAvailable @{ 'Course-Server1' = @{} }

$script:Oscdimg = 'Invoke-MockOscdimg'
$result = @(New-HyperVAnswerIso -Name 'Course-Server1' -ImageIndex 3 -Password 'TestPassword123!' `
    -IpAddress '192.168.252.10' -Gateway '192.168.252.1' -Dns '192.168.252.1' -PrefixLength 24 -OsKind 'Server')
if ($result.Count -ne 1 -or $result[0] -ne 'E:\TestLab\Course-Server1-answer.iso') { throw 'Vastaus-ISO:n paluuarvo on virheellinen.' }
[xml]$xml = $script:answerXml
$ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
$ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
if ($xml.SelectSingleNode('//u:Disk/u:WillWipeDisk', $ns).InnerText -ne 'true' -or
    $xml.SelectSingleNode('//u:InstallTo/u:PartitionID', $ns).InnerText -ne '3' -or
    $xml.SelectNodes('//u:CreatePartition', $ns).Count -ne 3) { throw 'UEFI-levymaarittely on virheellinen.' }

$script:HyperVVmInventory = @(
    [pscustomobject]@{ Name = 'Other'; Id = [guid]::NewGuid().ToString(); OS = 'Tuntematon'; State = 'Off'; CPU = 2; MemoryMB = 4096; Switch = 'Other' },
    [pscustomobject]@{ Name = 'Course-Server1'; Id = [guid]::NewGuid().ToString(); OS = 'Tuntematon'; State = 'Off'; CPU = 2; MemoryMB = 4096; Switch = 'Other' }
)
$script:answer = '1'
$adopted = Select-AdoptedVMs 'Hyper-V'
if ($adopted.Count -ne 1 -or $adopted['Course-Server1'].Name -ne 'Course-Server1' -or $script:questions -ne 1) {
    throw 'Hyper-V:n adoptointivalinta epaonnistui.'
}
$script:mockVms = @()
$script:mockNat = [pscustomobject]@{ Name = $script:HyperVNat; InternalIPInterfaceAddressPrefix = $network.Prefix }
$script:mockSwitch = [pscustomobject]@{ Name = $script:HyperVSwitch; SwitchType = 'Internal' }
$manifest = @{ Platform = 'Hyper-V'; Network = $network; VMs = @(); NatAdopted = $false; SwitchAdopted = $false; GatewayAddressCreated = $false }
$script:manifestJson = $manifest | ConvertTo-Json -Depth 5
$script:removed = @()
Remove-Lab
if ($script:removed.Count -ne 0) { throw 'Vanhan manifestin verkkoa tai tiedostoja poistettiin.' }
$manifest.ManifestVersion = 2
$script:manifestJson = $manifest | ConvertTo-Json -Depth 5
$script:mockVms = @([pscustomobject]@{ Name = 'Foreign'; Id = [guid]::NewGuid() })
$script:mockAttached = @([pscustomobject]@{ SwitchName = $script:HyperVSwitch })
Assert-Throws { Remove-Lab } 'ei kuulu manifestiin'
if ($script:removed.Count) { throw 'Ulkopuolisen Hyper-V VM:n kayttamaa verkkoa muutettiin.' }
$script:mockVms = @()
$script:mockAttached = @()
Remove-Lab
if ('nat' -notin $script:removed -or 'switch' -notin $script:removed -or $script:ManifestPath -notin $script:removed -or $script:LabRoot -in $script:removed) {
    throw 'Uuden manifestin verkkojen tai tiedostojen poisto oli virheellinen.'
}
$script:removed = @()
$manifest.Platform = 'VirtualBox'
$script:manifestJson = $manifest | ConvertTo-Json -Depth 5
$script:mockVBoxNats = "Name: WindowsCourseLab-NAT`nNetwork: 192.168.252.0/24`nDHCP Server: No`n"
$script:VBoxVmInventory = @([pscustomobject]@{ Name = 'Foreign'; Id = [guid]::NewGuid().ToString(); NatNetworks = @('WindowsCourseLab-NAT') })
Assert-Throws { Remove-Lab } 'labin ulkopuolinen VM'
if ($script:removed.Count) { throw 'Ulkopuolisen VirtualBox VM:n kayttamaa verkkoa muutettiin.' }
Write-Host 'PASS: verkko, resurssiristiriidat, tiedostosuojaus, UEFI-vastaustiedosto, adoptointi ja poistoturva.'
