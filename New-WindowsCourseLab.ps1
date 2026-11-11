[CmdletBinding()]
param(
    [ValidateSet('Check', 'Deploy', 'Remove')]
    [string]$Action = 'Check'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LabName = 'WindowsCourseLab'
$script:LabRoot = Join-Path $PSScriptRoot $script:LabName
$script:ManifestPath = Join-Path $script:LabRoot 'lab.json'
$script:HyperVSwitch = 'WindowsCourseLab-Internal'
$script:HyperVNat = 'WindowsCourseLab-NAT'
$script:VBoxNat = 'WindowsCourseLab-NAT'
$script:DefaultPrefix = '192.168.252.0/24'
$script:IsoMountApproved = $false

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-VBoxVmId {
    param([Parameter(Mandatory)][string]$Name)
    $output = (& (Get-VBoxManage) showvminfo $Name --machinereadable 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "VirtualBox VM-tunnuksen luku epaonnistui koneelle ${Name}: $output" }
    $match = [regex]::Match($output, '(?m)^UUID="?([0-9a-fA-F-]{36})"?$')
    if (-not $match.Success) { throw "VirtualBox VM-tunnusta ei saatu koneelle $Name." }
    return $match.Groups[1].Value
}

function Add-ManifestVm {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Id,
        [bool]$Adopted = $false,
        [hashtable]$Original
    )
    $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
    $records = @($manifest.VMs) + @([pscustomobject]@{
        Name = $Name
        Id = $Id
        Adopted = $Adopted
        Original = $Original
    })
    $manifest.VMs = $records
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:ManifestPath -Encoding UTF8
}

function Resolve-HyperVAnswerTool {
    $localTool = Join-Path $PSScriptRoot 'oscdimg.exe'
    if (Test-Path -LiteralPath $localTool -PathType Leaf) {
        $script:Oscdimg = (Resolve-Path -LiteralPath $localTool).Path
        Write-Host "Kaytetaan skriptin hakemistosta loytyvaa oscdimg.exe-tyokalua: $script:Oscdimg"
        return
    }
    $command = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($command) {
        $script:Oscdimg = $command.Source
        return
    }
    Write-Host 'Hyper-V:n valvomaton asennus tarvitsee Windows ADK:n oscdimg.exe-tyokalun.'
    Start-Process 'https://learn.microsoft.com/windows-hardware/get-started/adk-install'
    $path = Read-Host 'Anna itse asennetun oscdimg.exe-tiedoston polku'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'oscdimg.exe ei loytynyt. Hostia ei muutettu.' }
    $script:Oscdimg = (Resolve-Path -LiteralPath $path).Path
}

function Resolve-LabIso {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Prompt
    )
    $localIso = Join-Path $Directory $FileName
    if (Test-Path -LiteralPath $localIso -PathType Leaf) {
        $iso = $localIso
        Write-Host "Kaytetaan skriptin hakemistosta loytyvaa ISO-tiedostoa: $iso"
    }
    else {
        $iso = Read-Host $Prompt
    }
    if (-not $iso -or -not (Test-Path -LiteralPath $iso -PathType Leaf) -or
        [IO.Path]::GetExtension($iso) -ne '.iso') {
        throw "ISO-tiedostoa ei loytynyt tai tiedostopaate ei ole .iso: $iso"
    }
    return (Resolve-Path -LiteralPath $iso).Path
}

function Get-HostFacts {
    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $cpus = @(Get-CimInstance Win32_Processor)
    $cpu = $cpus | Select-Object -First 1
    $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
    [pscustomobject]@{
        Caption = $os.Caption
        Version = $os.Version
        Edition = $edition
        Is64Bit = [Environment]::Is64BitOperatingSystem
        TotalMemoryGB = [math]::Round($computer.TotalPhysicalMemory / 1GB, 1)
        FreeMemoryGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        VirtualizationEnabled = [bool]$cpu.VirtualizationFirmwareEnabled
        SLAT = [bool]$cpu.SecondLevelAddressTranslationExtensions
        HypervisorPresent = [bool]$computer.HypervisorPresent
        IsAdministrator = Test-IsAdministrator
    }
}

function Test-HostVirtualizationAvailable {
    param([Parameter(Mandatory)]$Facts)
    return ($Facts.HypervisorPresent -or ($Facts.VirtualizationEnabled -and $Facts.SLAT))
}

function Write-PlatformInventory {
    $script:HyperVVmInventory = @()
    $script:VBoxVmInventory = @()
    Write-Host "`nAsennettujen virtualisointialustojen nykytila (vain luku):"
    if (-not (Test-IsAdministrator)) {
        Write-Host 'Windows-ominaisuuksien tilat: tarkistus vaatii korotetun istunnon.'
    }
    elseif (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
        foreach ($featureName in @('Microsoft-Hyper-V-All', 'VirtualMachinePlatform', 'HypervisorPlatform')) {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction SilentlyContinue
            if ($feature) { Write-Host ("Windows-ominaisuus {0}: {1}" -f $featureName, $feature.State) }
        }
    }
    if (-not (Test-IsAdministrator)) {
        Write-Host 'Hyper-V-kytkimet, NAT-verkot ja virtuaalikoneet: tarkistus vaatii korotetun istunnon.'
    }
    elseif (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) {
        $switches = @(Get-VMSwitch -ErrorAction Stop)
        if ($switches.Count) {
            Write-Host 'Hyper-V-kytkimet:'
            $switches | Select-Object Name, SwitchType, NetAdapterInterfaceDescription | Format-Table -AutoSize | Out-Host
            foreach ($switch in $switches | Where-Object Name -eq $script:HyperVSwitch) {
                $adapter = Get-NetAdapter -Name "vEthernet ($($switch.Name))" -ErrorAction SilentlyContinue
                if ($adapter) {
                    $addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Select-Object IPAddress, PrefixLength)
                    Write-Host "Lab-kytkimen host-IP-asetukset ($($switch.Name)):"
                    if ($addresses.Count) { $addresses | Format-Table -AutoSize | Out-Host }
                    else { Write-Host 'IPv4-osoitetta ei ole maaritetty.' }
                }
            }
        }
        else { Write-Host 'Hyper-V-kytkimet: ei yhtaan' }
        $nats = @(Get-NetNat -ErrorAction Stop)
        if ($nats.Count) {
            Write-Host 'Hyper-V WinNAT -verkot:'
            $nats | Select-Object Name, InternalIPInterfaceAddressPrefix, Active | Format-Table -AutoSize | Out-Host
        }
        else { Write-Host 'Hyper-V WinNAT -verkot: ei yhtaan' }
        Write-Host "Labin oletusverkko: $($script:DefaultPrefix), NAT $($script:HyperVNat), kytkin $($script:HyperVSwitch)."
        if ($nats.Count -and -not ($nats | Where-Object Name -eq $script:HyperVNat)) {
            Write-Warning 'Hostilla on jo toinen WinNAT-verkko. Hyper-V-labin luonti pysahtyy; olemassa olevaa NATia ei muuteta.'
        }
        $vms = @(Get-VM -ErrorAction Stop)
        if ($vms.Count) {
            Write-Host 'Hyper-V-virtuaalikoneet ja niiden nykyiset asetukset:'
            $vmInventory = foreach ($vm in $vms) {
                $adapters = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop | ForEach-Object {
                    if ($_.SwitchName) { $_.SwitchName } else { '(ei kytketty)' }
                })
                $item = [pscustomobject]@{
                    Name = $vm.Name
                    Id = $vm.Id.Guid
                    State = $vm.State
                    OS = 'Tuntematon'
                    Generation = $vm.Generation
                    CPU = $vm.ProcessorCount
                    MemoryMB = [math]::Round($vm.MemoryStartup / 1MB)
                    Switch = $adapters -join ', '
                }
                $script:HyperVVmInventory += $item
                $item
            }
            $vmInventory | Select-Object Name, State, OS, Generation, CPU, MemoryMB, Switch | Format-List | Out-Host
        }
        else { Write-Host 'Hyper-V-virtuaalikoneet: ei yhtaan' }
    }
    else {
        Write-Host 'Hyper-V:n hallintatyokalut eivat ole kaytettavissa tassa istunnossa.'
    }

    $vbox = Get-VBoxManage
    if ($vbox) {
        $version = (& $vbox --version 2>&1 | Select-Object -First 1).ToString()
        if ($LASTEXITCODE -ne 0) { throw "VirtualBox-version tarkistus epaonnistui: $version" }
        Write-Host "VirtualBox: $version"
        $natnets = (& $vbox list natnets 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "VirtualBox NAT-verkkojen luku epaonnistui: $natnets" }
        Write-Host 'VirtualBox NAT Network -verkot ja asetukset:'
        if ($natnets.Trim()) { Write-Host $natnets } else { Write-Host 'Ei NAT Network -verkkoja.' }
        Write-Host "Labin tavoiteverkko: $($script:VBoxNat), $($script:DefaultPrefix), DHCP pois. Muut NAT-verkot ja niihin liitetyt VM:t jatkavat ennallaan."
        $vms = (& $vbox list vms 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "VirtualBox VM-listan luku epaonnistui: $vms" }
        Write-Host 'VirtualBox-virtuaalikoneet ja niiden asetukset:'
        if (-not $vms.Trim()) { Write-Host 'Ei virtuaalikoneita.' }
        else {
            $vmInventory = foreach ($line in ($vms -split "`r?`n")) {
                $match = [regex]::Match($line, '^"(.+)"\s+\{([0-9a-fA-F-]{36})\}$')
                if (-not $match.Success) { throw "VirtualBox VM-listan rivia ei voitu tunnistaa: $line" }
                $info = (& $vbox showvminfo $match.Groups[2].Value --machinereadable 2>&1) -join "`n"
                if ($LASTEXITCODE -ne 0) { throw "VirtualBox VM:n tietojen luku epaonnistui ($($match.Groups[1].Value)): $info" }
                $values = @{}
                foreach ($entry in ($info -split "`r?`n")) {
                    if ($entry -match '^([^=]+)="?(.*?)"?$') { $values[$matches[1]] = $matches[2] }
                }
                $natNetworks = @(
                    foreach ($key in $values.Keys | Where-Object { $_ -match '^nic\d+$' -and $values[$_] -eq 'natnetwork' }) {
                        $network = $values["nat-network$($key.Substring(3))"]
                        if (-not $network) { throw "VirtualBox VM:n $($match.Groups[1].Value) verkkokortin $key NAT-verkkoa ei voitu tunnistaa." }
                        $network
                    }
                )
                $item = [pscustomobject]@{
                    Name = $match.Groups[1].Value
                    Id = $match.Groups[2].Value
                    State = $values.VMState
                    OS = $values.ostype
                    CPU = $values.cpus
                    MemoryMB = $values.memory
                    NicType = $values['nic1']
                    NatNetwork = $values['nat-network1']
                    NatNetworks = $natNetworks
                    Adapter1 = "$($values['nic1']) $($values['nat-network1'])"
                    BridgeAdapter = $values['bridgeadapter1']
                    HostOnlyAdapter = $values['hostonlyadapter1']
                    InternalNetwork = $values['intnet1']
                    GenericDriver = $values['genericdrv1']
                    CableConnected = $values['cableconnected1']
                    Firmware = $values.firmware
                    TpmType = $values['tpm-type']
                }
                $script:VBoxVmInventory += $item
                $item
            }
            $vmInventory | Select-Object Name, State, OS, CPU, MemoryMB, Adapter1, Firmware, TpmType | Format-List | Out-Host
        }
    }
    else { Write-Host 'VirtualBox: ei asennettu' }
}

function Write-HostReport {
    $facts = Get-HostFacts
    Write-Host "`nHostin tarkistus (vain luku):"
    $facts | Format-List | Out-Host
    $hyperVState = 'Ei tiedossa'
    if (-not $facts.IsAdministrator) {
        $hyperVState = 'Ei tarkistettu (vaatii jarjestelmanvalvojan oikeudet)'
    }
    elseif (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
        if ($feature) { $hyperVState = [string]$feature.State }
    }
    $vboxPath = Get-VBoxManage
    Write-Host "Hyper-V-ominaisuus: $hyperVState"
    if ($vboxPath) {
        $vboxVersion = (& $vboxPath --version 2>&1 | Select-Object -First 1).ToString()
        Write-Host "VirtualBox: $vboxVersion ($vboxPath)"
    }
    else {
        Write-Host 'VirtualBox: ei asennettu'
    }
    if ($facts.Caption -notmatch 'Windows 11') {
        Write-Warning 'Tama skripti on suunniteltu Windows 11 -hostille.'
    }
    if ($facts.HypervisorPresent -and (-not $facts.VirtualizationEnabled -or -not $facts.SLAT)) {
        Write-Warning 'Windows havaitsee kaynnissa olevan hypervisorin, joten CIM:n firmware/SLAT-lippuja ei kayteta estona. Jos tama Windows on virtuaalikone, varmista sisakkaisvirtualisoinnin tuki.'
    }
    elseif (-not $facts.Is64Bit -or -not (Test-HostVirtualizationAvailable $facts)) {
        Write-Warning '64-bittinen host, laitteistovirtualisointi (UEFI/BIOS) ja SLAT vaaditaan. Tarkista prosessorin tuki ja laiteohjelmiston asetukset.'
    }
    if (-not $facts.IsAdministrator) {
        Write-Warning 'Kayttoonotto vaatii jarjestelmanvalvojan PowerShell-istunnon.'
    }
}

function Confirm-Change {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "`n$Message" -ForegroundColor Yellow
    return (Read-Host 'Jatketaanko? Kirjoita KYLLA') -ceq 'KYLLA'
}

function ConvertTo-IPv4Number {
    param([Parameter(Mandatory)][string]$Address)
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Virheellinen IPv4-osoite: $Address"
    }
    $bytes = $parsed.GetAddressBytes()
    return [uint64]$bytes[0] * 16777216 + [uint64]$bytes[1] * 65536 + [uint64]$bytes[2] * 256 + $bytes[3]
}

function ConvertFrom-IPv4Number {
    param([Parameter(Mandatory)][uint64]$Number)
    return '{0}.{1}.{2}.{3}' -f (($Number -shr 24) -band 255), (($Number -shr 16) -band 255), (($Number -shr 8) -band 255), ($Number -band 255)
}

function Get-NetworkRange {
    param([Parameter(Mandatory)][string]$Prefix)
    $parts = $Prefix.Split('/')
    if ($parts.Count -ne 2) { throw "Verkko tulee antaa muodossa IPv4/prefiksi: $Prefix" }
    $address = ConvertTo-IPv4Number $parts[0]
    $length = 0
    if (-not [int]::TryParse($parts[1], [ref]$length) -or $length -lt 0 -or $length -gt 32) {
        throw 'Verkon prefiksin tulee olla valilla /0 - /32.'
    }
    $mask = ([uint64][uint32]::MaxValue -shl (32 - $length)) -band [uint64][uint32]::MaxValue
    $start = $address -band $mask
    $end = $start + ([uint64][uint32]::MaxValue -bxor $mask)
    [pscustomobject]@{ Start = $start; End = $end; PrefixLength = $length; Network = ConvertFrom-IPv4Number $start }
}

function Test-PrefixConflict {
    param([Parameter(Mandatory)][string]$Prefix, [ValidateSet('Hyper-V', 'VirtualBox')][string]$Platform)
    $target = Get-NetworkRange $Prefix
    $labAdapter = $null
    if ($Platform -eq 'Hyper-V') {
        $labAdapter = Get-NetAdapter -Name "vEthernet ($script:HyperVSwitch)" -ErrorAction SilentlyContinue
    }
    foreach ($ip in Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop) {
        if ($ip.IPAddress -like '169.254.*' -or $ip.PrefixOrigin -eq 'WellKnown') { continue }
        $existing = Get-NetworkRange "$($ip.IPAddress)/$($ip.PrefixLength)"
        if ($target.Start -le $existing.End -and $existing.Start -le $target.End) {
            $gateway = ConvertFrom-IPv4Number ($target.Start + 1)
            if ($labAdapter -and $ip.InterfaceIndex -eq $labAdapter.ifIndex -and
                $ip.IPAddress -eq $gateway -and $ip.PrefixLength -eq $target.PrefixLength) { continue }
            return "Osoitealue $Prefix menee paallekkain hostin osoitteen $($ip.IPAddress)/$($ip.PrefixLength) kanssa."
        }
    }
    return $null
}

function ConvertTo-SubnetMask {
    param([Parameter(Mandatory)][int]$PrefixLength)
    $mask = ([uint64][uint32]::MaxValue -shl (32 - $PrefixLength)) -band [uint64][uint32]::MaxValue
    return ConvertFrom-IPv4Number $mask
}

function Get-VBoxManage {
    $commands = @(
        (Join-Path $env:ProgramFiles 'Oracle\VirtualBox\VBoxManage.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Oracle\VirtualBox\VBoxManage.exe')
    )
    foreach ($candidate in $commands) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    $command = Get-Command VBoxManage.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Assert-VBoxVersion {
    $exe = Get-VBoxManage
    if (-not $exe) { throw 'VBoxManage.exe ei loytynyt.' }
    $versionText = (& $exe --version 2>&1 | Select-Object -First 1).ToString()
    $match = [regex]::Match($versionText, '^(\d+)\.(\d+)')
    if (-not $match.Success -or [int]$match.Groups[1].Value -lt 7) {
        throw "VirtualBox 7.x tai uudempi vaaditaan Windows 11 -vieraan TPM-tuen vuoksi. Havaittu versio: $versionText"
    }
}

function Invoke-VBox {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $exe = Get-VBoxManage
    if (-not $exe) { throw 'VBoxManage.exe ei loytynyt.' }
    & $exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "VBoxManage-komento epaonnistui ($LASTEXITCODE): $($Arguments -join ' ')" }
}

function Test-LabResourceConflicts {
    param([ValidateSet('Hyper-V', 'VirtualBox')][string]$Platform, [string]$Prefix, [hashtable]$AdoptedVMs)
    $vmNames = @('Course-Server1', 'Course-Server2', 'Course-Client')
    if ($Platform -eq 'Hyper-V') {
        foreach ($name in $vmNames) {
            $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
            if ($vm -and (-not $AdoptedVMs.ContainsKey($name) -or
                [guid]$vm.Id -ne [guid]$AdoptedVMs[$name].Id)) {
                throw "VM $name on jo olemassa eika sita valittu saman lab-roolin adoptoitavaksi."
            }
        }
        $existingNat = @(Get-NetNat -ErrorAction Stop)
        if ($existingNat | Where-Object Name -ne $script:HyperVNat) {
            throw 'Hostilla on jo WinNAT-asetus; sita ei muuteta tai kayteta uudelleen.'
        }
        $labNat = $existingNat | Where-Object Name -eq $script:HyperVNat
        if ($labNat -and $labNat.InternalIPInterfaceAddressPrefix -ne $Prefix) {
            throw "Olemassa olevan WinNAT-verkon prefix on $($labNat.InternalIPInterfaceAddressPrefix), valittiin $Prefix. Verkkoa ei muuteta."
        }
        $switch = Get-VMSwitch -Name $script:HyperVSwitch -ErrorAction SilentlyContinue
        if ($switch -and $switch.SwitchType -ne 'Internal') { throw "Samanniminen Hyper-V-kytkin ei ole Internal-tyyppinen." }
    }
    else {
        $list = (& (Get-VBoxManage) list vms 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "VirtualBox VM-listan luku epaonnistui: $list" }
        foreach ($name in $vmNames) {
            $vmMatch = [regex]::Match($list, '(?m)^"{0}"\s+\{{([0-9a-fA-F-]{{36}})\}}' -f [regex]::Escape($name))
            if ($vmMatch.Success -and (-not $AdoptedVMs.ContainsKey($name) -or
                [guid]$vmMatch.Groups[1].Value -ne [guid]$AdoptedVMs[$name].Id)) {
                throw "VirtualBox VM $name on jo olemassa eika sita valittu saman lab-roolin adoptoitavaksi."
            }
        }
        $natList = (& (Get-VBoxManage) list natnets 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "VirtualBox NAT-verkkojen luku epaonnistui: $natList" }
        $requestedRange = Get-NetworkRange $Prefix
        $networkBlocks = [regex]::Matches($natList, '(?ms)^\s*(?:NetworkName|Name):\s*(?<name>[^\r\n]+)\s*$\r?\n(?<body>[\s\S]*?)(?=^\s*(?:NetworkName|Name):|\z)')
        foreach ($block in $networkBlocks) {
            if ($block.Groups['name'].Value.Trim() -eq $script:VBoxNat) { continue }
            $networkMatch = [regex]::Match($block.Groups['body'].Value, '(?m)^\s*Network:\s*(\d{1,3}(?:\.\d{1,3}){3}/\d{1,2})\s*$')
            if (-not $networkMatch.Success) { throw "VirtualBox NAT-verkon $($block.Groups['name'].Value.Trim()) osoitealuetta ei voitu tarkistaa." }
            $existingRange = Get-NetworkRange $networkMatch.Groups[1].Value
            if ($requestedRange.Start -le $existingRange.End -and $existingRange.Start -le $requestedRange.End) {
                throw "Valittu lab-verkko $Prefix menee paallekkain VirtualBox NAT-verkon $($block.Groups['name'].Value.Trim()) kanssa ($($networkMatch.Groups[1].Value))."
            }
        }
    }
}

function Initialize-Platform {
    param([ValidateSet('Hyper-V', 'VirtualBox')][string]$Platform)
    if (-not (Test-IsAdministrator)) {
        throw 'Aja skripti korotetussa (Run as administrator) PowerShell-istunnossa. Hostia ei muutettu.'
    }
    $facts = Get-HostFacts
    if ($facts.Caption -notmatch 'Windows 11' -or -not $facts.Is64Bit -or
        -not (Test-HostVirtualizationAvailable $facts)) {
        throw 'Host ei tayta Windows 11:n, 64-bittisyyden, laitteistovirtualisoinnin ja SLAT:n vaatimuksia.'
    }
    if ($Platform -eq 'Hyper-V') {
        $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
        if ($edition -notin @('Professional', 'ProfessionalN', 'Enterprise', 'EnterpriseN', 'Education', 'EducationN')) {
            throw "Hyper-V ei ole kaytettavissa Windows-versiossa $edition."
        }
        $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
        if ([string]$feature.State -match 'Pending') {
            throw 'Hyper-V:n muutokset odottavat uudelleenkaynnistysta. Kaynnista host uudelleen ja aja skripti uudelleen.'
        }
        if ($feature.State -ne 'Enabled') {
            if (-not (Confirm-Change 'Windowsin Hyper-V-ominaisuus otetaan kayttoon. Tama muuttaa Windowsin ominaisuuksia ja vaatii uudelleenkaynnistyksen.')) {
                throw 'Kayttaja peruutti Hyper-V:n kayttoonoton.'
            }
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All -NoRestart | Out-Host
            Write-Host 'Hyper-V otettiin kayttoon. Kaynnista host uudelleen ja aja skripti uudelleen.'
            exit 0
        }
    }
    else {
        $exe = Get-VBoxManage
        if (-not $exe) {
            Write-Host 'VirtualBox ei ole asennettuna. Avataan virallinen lataussivu.'
            Start-Process 'https://www.virtualbox.org/wiki/Downloads'
            $installer = Read-Host 'Anna virallisesti ladatun VirtualBox-asentimen MSI-polku'
            if (-not (Test-Path -LiteralPath $installer -PathType Leaf) -or [IO.Path]::GetExtension($installer) -ne '.msi') {
                throw 'Kelvollista MSI-asennustiedostoa ei annettu.'
            }
            if (-not (Confirm-Change "VirtualBox asennetaan tiedostosta $installer. Asennus lisaa ohjelmiston ja verkkokomponentit hostiin.")) {
                throw 'Kayttaja peruutti VirtualBox-asennuksen.'
            }
            $process = Start-Process msiexec.exe -ArgumentList @('/i', "`"$installer`"", '/passive', '/norestart') -Wait -PassThru
            if ($process.ExitCode -notin @(0, 3010)) { throw "VirtualBox-asennus epaonnistui: $($process.ExitCode)" }
            if ($process.ExitCode -eq 3010) {
                Write-Host 'VirtualBox asennettiin, mutta Windows vaatii uudelleenkaynnistyksen. Kaynnista uudelleen ja aja skripti uudelleen.'
            }
            else {
                Write-Host 'VirtualBox asennettiin. Sulje ja avaa PowerShell uudelleen, tarkista asennus ja aja skripti uudelleen.'
            }
            exit 0
        }
        Assert-VBoxVersion
    }
}

function Assert-PlatformPrerequisites {
    param([ValidateSet('Hyper-V', 'VirtualBox')][string]$Platform)
    if (-not (Test-IsAdministrator)) {
        throw 'Aja Deployment jarjestelmanvalvojan PowerShell-istunnossa. Hostia ei muutettu.'
    }
    $facts = Get-HostFacts
    if ($facts.Caption -notmatch 'Windows 11' -or -not $facts.Is64Bit -or
        -not (Test-HostVirtualizationAvailable $facts)) {
        throw 'Host ei tayta Windows 11:n, 64-bittisyyden, laitteistovirtualisoinnin ja SLAT:n vaatimuksia.'
    }
    if ($Platform -eq 'Hyper-V' -and $facts.Edition -notin @('Professional', 'ProfessionalN', 'Enterprise', 'EnterpriseN', 'Education', 'EducationN')) {
        throw "Hyper-V ei ole kaytettavissa Windows-versiossa $($facts.Edition)."
    }
    if ($Platform -eq 'VirtualBox') {
        $hyperVFeature = $null
        if (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
            $hyperVFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
        }
        if ($hyperVFeature -and $hyperVFeature.State -eq 'Enabled') {
            Write-Warning 'Hyper-V on jo kaytossa. VirtualBox voi toimia Hyper-V-taustalla hitaammin tai rajoitetusti; skripti ei muuta Hyper-V:n tilaa.'
        }
    }
}

function Get-ImageIndex {
    param([Parameter(Mandatory)][string]$IsoPath)
    if (-not $script:IsoMountApproved) {
        if (-not (Confirm-Change 'ISO-levyt liitetaan hetkeksi hostiin Windows-asennuskuvien lukemista varten ja irrotetaan heti.')) {
            throw 'Kayttaja ei hyvaksy ISO-levyjen tilapaista liittamista.'
        }
        $script:IsoMountApproved = $true
    }
    $existingImage = Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
    $wasAlreadyAttached = [bool]($existingImage -and $existingImage.Attached)
    $image = if ($wasAlreadyAttached) { $existingImage } else { Mount-DiskImage -ImagePath $IsoPath -PassThru }
    try {
        $drive = ($image | Get-Volume).DriveLetter
        if (-not $drive) { throw "ISO-levylle $IsoPath ei saatu asemakirjainta." }
        $imagePath = @("sources\install.wim", "sources\install.esd") |
            ForEach-Object { Join-Path "$($drive):\" $_ } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if (-not $imagePath) { throw "ISO:lta ei loytynyt sources\install.wim tai install.esd: $IsoPath" }
        Import-Module Dism -ErrorAction Stop
        $images = @(Get-WindowsImage -ImagePath $imagePath)
        if (-not $images) { throw "Windows-asennuskuvia ei loytynyt: $imagePath" }
        Write-Host "`nAsennuskuvat tiedostossa $IsoPath"
        $images | Select-Object ImageIndex, ImageName | Format-Table -AutoSize | Out-Host
        do {
            $raw = Read-Host 'Valitse ImageIndex taulukosta'
            $index = 0
        } until ([int]::TryParse($raw, [ref]$index) -and @($images | ForEach-Object ImageIndex) -contains $index)
        return $index
    }
    finally {
        if (-not $wasAlreadyAttached) {
            Dismount-DiskImage -ImagePath $IsoPath | Out-Null
        }
    }
}

function ConvertTo-PlainText {
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Set-PrivateAcl {
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($rule) }
    $inheritance = if ((Get-Item -LiteralPath $Path).PSIsContainer) { 'ContainerInherit,ObjectInherit' } else { 'None' }
    $identities = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User,
        [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    )
    foreach ($identity in $identities) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', $inheritance, 'None', 'Allow')
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Assert-PrivateDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $allowed = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        'S-1-5-18',
        'S-1-5-32-544'
    )
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($sid -notin $allowed) {
            throw "Lab-hakemiston $Path oikeudet sallivat paasyja muille kuin nykyiselle kayttajalle, SYSTEMille tai jarjestelmanvalvojille. Rajoita oikeudet itse ennen kayttoonottoa; vastaustiedostot sisaltavat salasanoja."
        }
    }
}

function New-HyperVAnswerIso {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$ImageIndex,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][string]$Gateway,
        [Parameter(Mandatory)][string]$Dns,
        [Parameter(Mandatory)][int]$PrefixLength,
        [Parameter(Mandatory)][string]$OsKind
    )
    $stage = Join-Path $script:LabRoot "$Name-answer"
    $answerIso = Join-Path $script:LabRoot "$Name-answer.iso"
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Set-PrivateAcl $stage
    $escapedPassword = [Security.SecurityElement]::Escape($Password)
    $escapedName = [Security.SecurityElement]::Escape($Name)
    $networkScript = @"
`$ErrorActionPreference = 'Stop'
`$nic = `$null
for (`$attempt = 0; `$attempt -lt 30 -and -not `$nic; `$attempt++) {
    `$nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    if (-not `$nic) { Start-Sleep -Seconds 2 }
}
if (-not `$nic) { throw 'Lab adapter was not found during specialize.' }
New-NetIPAddress -InterfaceIndex `$nic.ifIndex -IPAddress '$IpAddress' -PrefixLength $PrefixLength -DefaultGateway '$Gateway' -ErrorAction Stop
Set-DnsClientServerAddress -InterfaceIndex `$nic.ifIndex -ServerAddresses '$Dns' -ErrorAction Stop
"@
    $encodedNetwork = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($networkScript))
    $setupComponent = '<component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><DiskConfiguration><Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk><CreatePartitions><CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition><CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition><CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition></CreatePartitions><ModifyPartitions><ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition><ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition></ModifyPartitions></Disk><WillShowUI>OnError</WillShowUI></DiskConfiguration><UserData><AcceptEula>true</AcceptEula></UserData><ImageInstall><OSImage><InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>{0}</Value></MetaData></InstallFrom><InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo></OSImage></ImageInstall></component>' -f $ImageIndex
    $specializeShell = '<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><ComputerName>{0}</ComputerName><TimeZone>FLE Standard Time</TimeZone></component>' -f $escapedName
    $oobeShell = if ($OsKind -eq 'Server') {
        '<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><UserAccounts><AdministratorPassword><Value>{0}</Value><PlainText>true</PlainText></AdministratorPassword></UserAccounts><OOBE><HideEULAPage>true</HideEULAPage><ProtectYourPC>3</ProtectYourPC></OOBE></component>' -f $escapedPassword
    }
    else {
        '<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"><UserAccounts><LocalAccounts><LocalAccount wcm:action="add"><Password><Value>{0}</Value><PlainText>true</PlainText></Password><Group>Administrators</Group><Name>LabAdmin</Name><DisplayName>Course Lab Admin</DisplayName></LocalAccount></LocalAccounts></UserAccounts><OOBE><HideEULAPage>true</HideEULAPage><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC></OOBE></component>' -f $escapedPassword
    }
    $answer = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">$setupComponent</settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous><RunSynchronousCommand wcm:action="add"><Order>1</Order><Description>Configure isolated lab network</Description><Path>powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedNetwork</Path></RunSynchronousCommand></RunSynchronous>
    </component>
    $specializeShell
  </settings>
  <settings pass="oobeSystem">
    $oobeShell
  </settings>
</unattend>
"@
    $answerPath = Join-Path $stage 'Autounattend.xml'
    Set-Content -LiteralPath $answerPath -Value $answer -Encoding UTF8
    Set-PrivateAcl $answerPath
    try {
        & $script:Oscdimg -u2 -udfver102 -lLABANSWER $stage $answerIso | Out-Host
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $answerIso)) {
            throw "oscdimg.exe epaonnistui vastaustiedoston ISO:n luomisessa ($LASTEXITCODE)."
        }
        Set-PrivateAcl $answerIso
    }
    finally {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    return $answerIso
}

function Grant-HyperVVmReadAccess {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$VM)
    $vmAccount = [Security.Principal.NTAccount]::new("NT VIRTUAL MACHINE\$($VM.Id.Guid)")
    $isDirectory = (Get-Item -LiteralPath $Path).PSIsContainer
    $rights = if ($isDirectory) { 'Modify' } else { 'ReadAndExecute' }
    $inheritance = if ($isDirectory) { 'ContainerInherit,ObjectInherit' } else { 'None' }
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($vmAccount, $rights, $inheritance, 'None', 'Allow')
    $acl = Get-Acl -LiteralPath $Path
    [void]$acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-IPv4Addresses {
    param([Parameter(Mandatory)][string]$Prefix)
    $range = Get-NetworkRange $Prefix
    if ($range.PrefixLength -lt 16 -or $range.PrefixLength -gt 28) {
        throw 'Lab-verkon prefiksin tulee olla valilla /16 - /28, jotta kiinteat osoitteet mahtuvat verkkoon.'
    }
    $octets = $range.Network.Split('.') | ForEach-Object { [int]$_ }
    $isPrivate = $octets[0] -eq 10 -or
        ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 168)
    if (-not $isPrivate) { throw 'Lab-verkon tulee kayttaa RFC1918-yksityista IPv4-osoitealuetta.' }
    $networkNumber = ConvertTo-IPv4Number $range.Network
    [pscustomobject]@{
        Prefix = "$($range.Network)/$($range.PrefixLength)"
        Gateway = ConvertFrom-IPv4Number ($networkNumber + 1)
        PrefixLength = $range.PrefixLength
        Netmask = ConvertTo-SubnetMask $range.PrefixLength
        Guests = @(
            (ConvertFrom-IPv4Number ($networkNumber + 10)),
            (ConvertFrom-IPv4Number ($networkNumber + 11)),
            (ConvertFrom-IPv4Number ($networkNumber + 12))
        )
    }
}

function New-HyperVEnvironment {
    param([hashtable]$Config)
    $existingNat = @(Get-NetNat -ErrorAction Stop)
    $labNat = $existingNat | Where-Object Name -eq $script:HyperVNat
    if ($existingNat | Where-Object Name -ne $script:HyperVNat) {
        throw 'Hostilla on jo WinNAT-asetus. Sita ei muuteta tai kayteta uudelleen.'
    }
    $switch = Get-VMSwitch -Name $script:HyperVSwitch -ErrorAction SilentlyContinue
    if ($switch -and $switch.SwitchType -ne 'Internal') {
        throw "Hyper-V-kytkin $script:HyperVSwitch on tyypiltaan $($switch.SwitchType), odotettiin Internal. Sita ei muuteta."
    }
    $script:SwitchAdopted = $true
    $script:NatAdopted = $true
    $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
    $manifest.NatAdopted = $script:NatAdopted
    $manifest.SwitchAdopted = $script:SwitchAdopted
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ManifestPath -Encoding UTF8
    Set-PrivateAcl $script:ManifestPath
    if (-not $switch) {
        $switch = New-VMSwitch -Name $script:HyperVSwitch -SwitchType Internal
        $script:SwitchAdopted = $false
        $manifest.SwitchAdopted = $false
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ManifestPath -Encoding UTF8
        Set-PrivateAcl $script:ManifestPath
    }
    $adapter = Get-NetAdapter -Name "vEthernet ($script:HyperVSwitch)" -ErrorAction Stop
    $adoptedIds = @($Config.AdoptedVMs.Values | ForEach-Object { ([guid]$_.Id).ToString('D') })
    $attached = @(
        foreach ($vm in Get-VM -ErrorAction Stop) {
            foreach ($networkAdapter in Get-VMNetworkAdapter -VM $vm -ErrorAction Stop) {
                if ($networkAdapter.SwitchName -eq $script:HyperVSwitch) {
                    [pscustomobject]@{
                        VMId = ([guid]$vm.Id).ToString('D')
                        VMName = $vm.Name
                    }
                }
            }
        }
    )
    $foreign = @($attached | Where-Object { $_.VMId -notin $adoptedIds })
    if ($foreign.Count) {
        $foreignNames = ($foreign | ForEach-Object { "'$($_.VMName)' (VMId $($_.VMId))" }) -join ', '
        throw "Lab-kytkinta kayttavat olemassa olevat VM:t, joita ei valittu adoptoitaviksi: $foreignNames. Valitse ne adoptoitaviksi tai irrota ne kytkimesta ennen kayttoonottoa."
    }
    $existingAddress = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' })
    if (@($existingAddress | Where-Object IPAddress -ne $Config.Network.Gateway).Count) {
        throw "Lab-kytkimella on ennestaan IPv4-osoite. Skripti ei muuta sita."
    }
    $gatewayAddress = $existingAddress | Where-Object IPAddress -eq $Config.Network.Gateway | Select-Object -First 1
    if ($gatewayAddress -and $gatewayAddress.PrefixLength -ne $Config.Network.PrefixLength) {
        throw "Lab-kytkimen yhdyskaytavan $($Config.Network.Gateway) prefiksi on $($gatewayAddress.PrefixLength), valittiin $($Config.Network.PrefixLength). Skripti ei muuta sita automaattisesti."
    }
    $gatewayExists = [bool](Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object IPAddress -eq $Config.Network.Gateway)
    $script:GatewayAddressCreated = $false
    if (-not $gatewayExists) {
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $Config.Network.Gateway -PrefixLength $Config.Network.PrefixLength | Out-Null
        $script:GatewayAddressCreated = $true
        if ($script:SwitchAdopted) {
            $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
            $manifest.GatewayAddressCreated = $true
            $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ManifestPath -Encoding UTF8
            Set-PrivateAcl $script:ManifestPath
        }
    }
    if ($labNat -and $labNat.InternalIPInterfaceAddressPrefix -ne $Config.Network.Prefix) {
        throw "Olemassa olevan WinNAT-verkon prefix on $($labNat.InternalIPInterfaceAddressPrefix), valittiin $($Config.Network.Prefix). NATia ei muuteta automaattisesti."
    }
    if (-not $labNat) {
        New-NetNat -Name $script:HyperVNat -InternalIPInterfaceAddressPrefix $Config.Network.Prefix | Out-Null
        $script:NatAdopted = $false
        $manifest.NatAdopted = $false
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ManifestPath -Encoding UTF8
        Set-PrivateAcl $script:ManifestPath
    }
    $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
    $manifest.NatAdopted = $script:NatAdopted
    $manifest.SwitchAdopted = $script:SwitchAdopted
    $manifest.GatewayAddressCreated = $script:GatewayAddressCreated
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ManifestPath -Encoding UTF8
    Set-PrivateAcl $script:ManifestPath
    $vmSpecs = @(
        @{ Name = 'Course-Server1'; Iso = $Config.ServerIso[0]; Index = $Config.ServerIndex[0]; Ip = $Config.Network.Guests[0]; Kind = 'Server'; Memory = $Config.ServerMemory; Cpu = $Config.ServerCpu; Disk = $Config.ServerDisk },
        @{ Name = 'Course-Server2'; Iso = $Config.ServerIso[1]; Index = $Config.ServerIndex[1]; Ip = $Config.Network.Guests[1]; Kind = 'Server'; Memory = $Config.ServerMemory; Cpu = $Config.ServerCpu; Disk = $Config.ServerDisk },
        @{ Name = 'Course-Client'; Iso = $Config.ClientIso; Index = $Config.ClientIndex; Ip = $Config.Network.Guests[2]; Kind = 'Client'; Memory = $Config.ClientMemory; Cpu = $Config.ClientCpu; Disk = $Config.ClientDisk }
    )
    foreach ($spec in $vmSpecs) {
        if ($Config.AdoptedVMs.ContainsKey($spec.Name)) {
            $existing = Get-VM -Id ([guid]$Config.AdoptedVMs[$spec.Name].Id) -ErrorAction Stop
            if ($existing.State -ne 'Off' -or $existing.Generation -ne 2) {
                throw "Adoptoitavan Hyper-V VM:n $($existing.Name) tulee olla sammutettu Generation 2 -VM."
            }
            $memory = Get-VMMemory -VM $existing
            $adapters = @(Get-VMNetworkAdapter -VM $existing)
            if ($adapters.Count -ne 1) { throw "Adoptoitavassa VM:ssa $($existing.Name) tulee olla tasan yksi verkkokortti." }
            $original = @{
                CPU = $existing.ProcessorCount
                MemoryStartup = [int64]$memory.Startup
                DynamicMemoryEnabled = [bool]$memory.DynamicMemoryEnabled
                MemoryMinimum = [int64]$memory.Minimum
                MemoryMaximum = [int64]$memory.Maximum
                SwitchName = $adapters[0].SwitchName
            }
            Write-Host "Adoptointi: $($existing.Name) -> $($spec.Name); CPU $($original.CPU) -> $($spec.Cpu), muisti $([math]::Round($original.MemoryStartup / 1MB)) -> $($spec.Memory) MB, kytkin '$($original.SwitchName)' -> '$script:HyperVSwitch'."
            if (-not (Confirm-Change "Muuta sammutetun Hyper-V VM:n $($existing.Name) CPU-, muistija verkkokorttiasetukset? Virtuaalilevyja ja vieraskayttojarjestelmaa ei alusteta; vieraan IP-asetus on tarkistettava kasin.")) {
                throw "Kayttaja peruutti VM:n $($existing.Name) adoptoinnin."
            }
            Add-ManifestVm -Name $spec.Name -Id $existing.Id.Guid -Adopted $true -Original $original
            Set-VMProcessor -VM $existing -Count $spec.Cpu
            Set-VMMemory -VM $existing -DynamicMemoryEnabled $false -StartupBytes ($spec.Memory * 1MB)
            Connect-VMNetworkAdapter -VMNetworkAdapter $adapters[0] -SwitchName $script:HyperVSwitch
            continue
        }
        if (Get-VM -Name $spec.Name -ErrorAction SilentlyContinue) { throw "VM $($spec.Name) on jo olemassa eika sita valittu adoptoitavaksi." }
        $answerIso = New-HyperVAnswerIso -Name $spec.Name -ImageIndex $spec.Index -Password $Config.GuestCredentials[$spec.Name] `
                -IpAddress $spec.Ip -Gateway $Config.Network.Gateway -Dns $Config.Dns `
                -PrefixLength $Config.Network.PrefixLength -OsKind $spec.Kind
        $vmPath = Join-Path $script:LabRoot $spec.Name
        New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
        $vm = New-VM -Name $spec.Name -Generation 2 -MemoryStartupBytes ($spec.Memory * 1MB) `
            -NewVHDPath (Join-Path $vmPath "$($spec.Name).vhdx") -NewVHDSizeBytes ($spec.Disk * 1GB) `
            -Path $vmPath -SwitchName $script:HyperVSwitch
        Add-ManifestVm -Name $spec.Name -Id $vm.Id.Guid
        Grant-HyperVVmReadAccess -Path $vmPath -VM $vm
        Set-VMProcessor -VMName $spec.Name -Count $spec.Cpu
        Set-VMFirmware -VMName $spec.Name -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
        if ($spec.Kind -eq 'Client') {
            Set-VMKeyProtector -VMName $spec.Name -NewLocalKeyProtector
            Enable-VMTPM -VMName $spec.Name
        }
        Add-VMDvdDrive -VMName $spec.Name -Path $spec.Iso | Out-Null
        Add-VMDvdDrive -VMName $spec.Name -Path $answerIso | Out-Null
        Grant-HyperVVmReadAccess -Path $spec.Iso -VM $vm
        Grant-HyperVVmReadAccess -Path $answerIso -VM $vm
        $dvd = Get-VMDvdDrive -VMName $spec.Name | Where-Object Path -eq $spec.Iso | Select-Object -First 1
        Set-VMFirmware -VMName $spec.Name -FirstBootDevice $dvd
        Start-VM -Name $spec.Name | Out-Null
    }
}

function New-VBoxEnvironment {
    param([hashtable]$Config)
    $networkName = $script:VBoxNat
    $natList = (& (Get-VBoxManage) list natnets 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "VirtualBox NAT-verkkojen tarkistus epaonnistui: $natList" }
    $natPattern = '(?ms)^\s*(?:NetworkName|Name):\s+{0}\s*$([\s\S]*?)(?=^\s*(?:NetworkName|Name):|\z)' -f [regex]::Escape($networkName)
    $natEntry = [regex]::Match($natList, $natPattern)
    if ($natEntry.Success) {
        $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
        $manifest.NatAdopted = $true
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ManifestPath -Encoding UTF8
        Set-PrivateAcl $script:ManifestPath
        $details = $natEntry.Groups[1].Value
        $networkMatch = [regex]::Match($details, '(?m)^\s*Network:\s*(\S+)\s*$')
        $dhcpMatch = [regex]::Match($details, '(?m)^\s*DHCP Server:\s*(Yes|No)\s*$')
        if (-not $networkMatch.Success -or -not $dhcpMatch.Success) {
            throw "VirtualBox NAT-verkon $networkName asetuksia ei voitu tunnistaa turvallisesti."
        }
        $dhcpEnabled = $dhcpMatch.Groups[1].Value -eq 'Yes'
        $adoptedIds = @($Config.AdoptedVMs.Values | ForEach-Object Id)
        $otherUsers = @($script:VBoxVmInventory | Where-Object {
            $_.NatNetworks -contains $networkName -and $_.Id -notin $adoptedIds
        })
        if ($otherUsers.Count) {
            throw "Labin NAT-verkkoa $networkName kayttavat muut VM:t ($($otherUsers.Name -join ', ')); niita ei liiteta labin hallintaan."
        }
        if ($networkMatch.Groups[1].Value -ne $Config.Network.Prefix -or $dhcpEnabled) {
            Write-Host "VirtualBox NAT-verkon asetusero: Network $($networkMatch.Groups[1].Value) -> $($Config.Network.Prefix); DHCP $($dhcpMatch.Groups[1].Value) -> No."
            if (-not (Confirm-Change "Muuta olemassa olevan VirtualBox NAT-verkon $networkName osoitealuetta ja poistaa DHCP-palvelin kaytosta? Liikenne keskeytyy hetkeksi.")) {
                throw 'Kayttaja peruutti NAT-verkon asetusten muutoksen.'
            }
            $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
            $manifest.OriginalNat = @{
                Network = $networkMatch.Groups[1].Value
                DhcpEnabled = $dhcpEnabled
            }
            $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ManifestPath -Encoding UTF8
            Set-PrivateAcl $script:ManifestPath
            Invoke-VBox @('natnetwork', 'modify', '--netname', $networkName, '--network', $Config.Network.Prefix, '--dhcp', 'off')
        }
        $script:NetworkAdopted = $true
    }
    else {
        $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
        Invoke-VBox @('natnetwork', 'add', '--netname', $networkName, '--network', $Config.Network.Prefix, '--enable', '--dhcp', 'off')
        $script:NetworkAdopted = $false
    }
    $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
    $manifest.NatAdopted = $script:NetworkAdopted
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ManifestPath -Encoding UTF8
    Set-PrivateAcl $script:ManifestPath
    Invoke-VBox @('natnetwork', 'start', '--netname', $networkName)
    $vmSpecs = @(
        @{ Name = 'Course-Server1'; Iso = $Config.ServerIso[0]; Index = $Config.ServerIndex[0]; Ip = $Config.Network.Guests[0]; Kind = 'Server'; Memory = $Config.ServerMemory; Cpu = $Config.ServerCpu; Disk = $Config.ServerDisk; OsType = 'Windows2019_64' },
        @{ Name = 'Course-Server2'; Iso = $Config.ServerIso[1]; Index = $Config.ServerIndex[1]; Ip = $Config.Network.Guests[1]; Kind = 'Server'; Memory = $Config.ServerMemory; Cpu = $Config.ServerCpu; Disk = $Config.ServerDisk; OsType = 'Windows2019_64' },
        @{ Name = 'Course-Client'; Iso = $Config.ClientIso; Index = $Config.ClientIndex; Ip = $Config.Network.Guests[2]; Kind = 'Client'; Memory = $Config.ClientMemory; Cpu = $Config.ClientCpu; Disk = $Config.ClientDisk; OsType = 'Windows11_64' }
    )
    foreach ($spec in $vmSpecs) {
        if ($Config.AdoptedVMs.ContainsKey($spec.Name)) {
            $existing = $Config.AdoptedVMs[$spec.Name]
            $info = (& (Get-VBoxManage) showvminfo $existing.Id --machinereadable 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0) { throw "Adoptoitavan VirtualBox VM:n tietojen luku epaonnistui: $info" }
            $values = @{}
            foreach ($entry in ($info -split "`r?`n")) {
                if ($entry -match '^([^=]+)="?(.*?)"?$') { $values[$matches[1]] = $matches[2] }
            }
            if ($values.VMState -ne 'poweroff') { throw "Adoptoitava VM $($existing.Name) ei ole sammutettu." }
            $original = @{
                CPU = $values.cpus
                MemoryMB = $values.memory
                NicType = $values['nic1']
                NatNetwork = $values['nat-network1']
                BridgeAdapter = $values['bridgeadapter1']
                HostOnlyAdapter = $values['hostonlyadapter1']
                InternalNetwork = $values['intnet1']
                GenericDriver = $values['genericdrv1']
                CableConnected = $values['cableconnected1']
            }
            if ($original.NicType -notin @('nat', 'natnetwork', 'bridged', 'hostonly', 'intnet', 'none', 'generic')) {
                throw "VM:n $($existing.Name) verkkokorttityyppia '$($original.NicType)' ei tueta turvallisessa adoptoinnissa."
            }
            if (($original.NicType -eq 'natnetwork' -and -not $original.NatNetwork) -or
                ($original.NicType -eq 'bridged' -and -not $original.BridgeAdapter) -or
                ($original.NicType -eq 'hostonly' -and -not $original.HostOnlyAdapter) -or
                ($original.NicType -eq 'intnet' -and -not $original.InternalNetwork) -or
                ($original.NicType -eq 'generic' -and -not $original.GenericDriver)) {
                throw "VM:n $($existing.Name) alkuperaisia verkkokorttiasetuksia ei voitu lukea palautusta varten; sita ei adoptoida."
            }
            Write-Host "Adoptointi: $($existing.Name) -> $($spec.Name); CPU $($original.CPU) -> $($spec.Cpu), muisti $($original.MemoryMB) -> $($spec.Memory) MB, verkko $($existing.Adapter1) -> NAT $networkName."
            if (-not (Confirm-Change "Muuta sammutetun VM:n $($existing.Name) CPU-, muistija verkkokorttiasetukset labia varten? Virtuaalilevyja ja vieraskayttojarjestelmaa ei muuteta; vieraan IP-asetus on tarkistettava kasin.")) {
                throw "Kayttaja peruutti VM:n $($existing.Name) adoptoinnin."
            }
            Add-ManifestVm -Name $spec.Name -Id $existing.Id -Adopted $true -Original $original
            $arguments = @('modifyvm', $existing.Id, '--memory', [string]$spec.Memory, '--cpus', [string]$spec.Cpu,
                '--nic1', 'natnetwork', '--nat-network1', $networkName, '--cableconnected1', 'on')
            Invoke-VBox $arguments
            continue
        }
        Invoke-VBox @('createvm', '--name', $spec.Name, '--ostype', $spec.OsType, '--register', '--basefolder', $script:LabRoot)
        Add-ManifestVm -Name $spec.Name -Id (Get-VBoxVmId $spec.Name)
        Invoke-VBox @('modifyvm', $spec.Name, '--memory', [string]$spec.Memory, '--cpus', [string]$spec.Cpu, '--firmware', 'efi', '--tpm-type', '2.0',
            '--ioapic', 'on', '--nic1', 'natnetwork', '--nat-network1', $networkName, '--boot1', 'dvd', '--boot2', 'disk')
        Invoke-VBox @('createmedium', 'disk', '--filename', (Join-Path $script:LabRoot "$($spec.Name).vdi"), '--size', [string]($spec.Disk * 1024), '--format', 'VDI')
        Invoke-VBox @('storagectl', $spec.Name, '--name', 'SATA', '--add', 'sata', '--controller', 'IntelAhci')
        Invoke-VBox @('storageattach', $spec.Name, '--storagectl', 'SATA', '--port', '0', '--device', '0', '--type', 'hdd',
            '--medium', (Join-Path $script:LabRoot "$($spec.Name).vdi"))
        Invoke-VBox @('storageattach', $spec.Name, '--storagectl', 'SATA', '--port', '1', '--device', '0', '--type', 'dvddrive', '--medium', $spec.Iso)
        $passwordFile = Join-Path $script:LabRoot "$($spec.Name).password"
        try {
            [IO.File]::WriteAllText($passwordFile, $Config.GuestCredentials[$spec.Name], [Text.UTF8Encoding]::new($false))
            Set-PrivateAcl $passwordFile
            $networkCommand = "`$ErrorActionPreference='Stop'; `$nic=`$null; for (`$i=0; `$i -lt 30 -and -not `$nic; `$i++) { `$nic=Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1; if (-not `$nic) { Start-Sleep -Seconds 2 } }; if (-not `$nic) { throw 'Lab adapter was not found' }; New-NetIPAddress -InterfaceIndex `$nic.ifIndex -IPAddress $($spec.Ip) -PrefixLength $($Config.Network.PrefixLength) -DefaultGateway $($Config.Network.Gateway); Set-DnsClientServerAddress -InterfaceIndex `$nic.ifIndex -ServerAddresses '$($Config.Dns)'"
            $networkEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($networkCommand))
            $postInstall = "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $networkEncoded"
            Invoke-VBox @('unattended', 'install', $spec.Name, '--iso', $spec.Iso, '--user', 'LabAdmin',
                '--full-user-name', 'Course Lab Admin', '--user-password-file', $passwordFile,
                '--admin-password-file', $passwordFile, '--image-index', [string]$spec.Index,
                '--auxiliary-base-path', (Join-Path $script:LabRoot "$($spec.Name)-unattended"),
                '--hostname', $spec.Name, '--time-zone', 'FLE Standard Time',
                '--post-install-command', $postInstall, '--start-vm', 'gui')
        }
        finally {
            if (Test-Path -LiteralPath $passwordFile) { Remove-Item -LiteralPath $passwordFile -Force }
        }
    }
}

function Read-DeploymentConfig {
    param([ValidateSet('Hyper-V', 'VirtualBox')][string]$Platform, [hashtable]$AdoptedVMs)
    if (-not (Test-IsAdministrator)) { throw 'Deployment vaatii korotetun PowerShell-istunnon.' }
    $facts = Get-HostFacts
    Start-Process 'https://www.microsoft.com/software-download/windows11'
    Start-Process 'https://www.microsoft.com/evalcenter/'
    $prefix = Read-Host "Syota lab-verkon osoitealue (oletus $script:DefaultPrefix)"
    if (-not $prefix) { $prefix = $script:DefaultPrefix }
    $conflict = Test-PrefixConflict -Prefix $prefix -Platform $Platform
    if ($conflict) { throw $conflict }
    $network = Get-IPv4Addresses $prefix
    $dnsServers = @(Get-DnsClientServerAddress -AddressFamily IPv4 |
        ForEach-Object { $_.ServerAddresses } |
        Where-Object { $_ -and $_ -notlike '127.*' -and $_ -notlike '169.254.*' } |
        Select-Object -Unique)
    if ($dnsServers.Count -gt 0) {
        $dns = [string]$dnsServers[0]
        Write-Host "DNS-palvelin hostin asetuksista: $dns"
        $newDns = Read-Host 'DNS-osoite (Enter kayttaa ehdotettua)'
        if ($newDns) { [void](ConvertTo-IPv4Number $newDns); $dns = $newDns }
    }
    else {
        $dns = Read-Host 'Hostilta ei loytynyt DNS-palvelinta. Syota kaytettava IPv4 DNS-osoite'
        [void](ConvertTo-IPv4Number $dns)
    }

    Write-Host "`nISO-tiedostot: skriptin hakemistosta kaytetaan server.iso ja win11.iso, jos ne loytyvat; muuten polut kysytaan. Oletus on Evaluation-media; tuoteavaimia ei kysyta tai maariteta."
    $serverIso1 = $null
    $serverIso2 = $null
    $clientIso = $null
    if (-not $AdoptedVMs.ContainsKey('Course-Server1')) {
        $serverIso1 = Resolve-LabIso -Directory $PSScriptRoot -FileName 'server.iso' -Prompt 'Windows Server 2019 Evaluation ISO -polku (Server 1)'
    }
    if (-not $AdoptedVMs.ContainsKey('Course-Server2')) {
        $serverIso2 = Resolve-LabIso -Directory $PSScriptRoot -FileName 'server.iso' -Prompt 'Windows Server 2019 Evaluation ISO -polku (Server 2)'
    }
    if (-not $AdoptedVMs.ContainsKey('Course-Client')) {
        $clientIso = Resolve-LabIso -Directory $PSScriptRoot -FileName 'win11.iso' -Prompt 'Windows 11 ISO -polku (Client)'
    }
    $serverIndex1 = if ($serverIso1) { Get-ImageIndex $serverIso1 } else { $null }
    $serverIndex2 = if ($serverIso2) { Get-ImageIndex $serverIso2 } else { $null }
    $clientIndex = if ($clientIso) { Get-ImageIndex $clientIso } else { $null }
    $serverMemory = 4096
    $clientMemory = 8192
    $memoryChoice = Read-Host "VM-muisti MB: palvelimet $serverMemory, tyokone $clientMemory; Enter hyvaksyy, tai anna esim. 4096,6144"
    if ($memoryChoice) {
        $parts = $memoryChoice.Split(',')
        if ($parts.Count -ne 2 -or [int]$parts[0] -lt 2048 -or [int]$parts[1] -lt 4096) { throw 'Virheelliset muistiarvot.' }
        $serverMemory = [int]$parts[0]
        $clientMemory = [int]$parts[1]
    }
    $serverCpu = 2
    $clientCpu = 2
    $serverDisk = 80
    $clientDisk = 80
    $resourceChoice = Read-Host 'VM-resurssit sCPU,cCPU,sDiskGB,cDiskGB (Enter = 2,2,80,80)'
    if ($resourceChoice) {
        $parts = $resourceChoice.Split(',')
        if ($parts.Count -ne 4) { throw 'Anna resurssit muodossa sCPU,cCPU,sDiskGB,cDiskGB.' }
        try {
            $serverCpu, $clientCpu, $serverDisk, $clientDisk = $parts | ForEach-Object { [int]$_.Trim() }
        }
        catch { throw 'Resurssiarvojen tulee olla kokonaislukuja.' }
        if ($serverCpu -lt 1 -or $clientCpu -lt 1 -or $serverDisk -lt 64 -or $clientDisk -lt 64) {
            throw 'CPU-maaran tulee olla vahintaan 1 ja levyn vahintaan 64 GiB.'
        }
    }
    $driveLetter = [IO.Path]::GetPathRoot($PSScriptRoot).Substring(0, 1)
    $freeSpaceGB = (Get-Volume -DriveLetter $driveLetter).SizeRemaining / 1GB
    $newServerCount = @('Course-Server1', 'Course-Server2') |
        Where-Object { -not $AdoptedVMs.ContainsKey($_) } |
        Measure-Object | Select-Object -ExpandProperty Count
    $newClientCount = if ($AdoptedVMs.ContainsKey('Course-Client')) { 0 } else { 1 }
    $maximumDiskGB = $newServerCount * $serverDisk + $newClientCount * $clientDisk
    if ($maximumDiskGB -gt 0 -and $freeSpaceGB -lt $maximumDiskGB) {
        Write-Warning "Labin kohdelevyllä on $([math]::Floor($freeSpaceGB)) GiB vapaata, kun virtuaalilevyjen yhteenlaskettu enimmäiskoko on $maximumDiskGB GiB. Dynaamiset levyt kuluttavat aluksi vähemmän, mutta voivat kasvaa enimmäiskokoonsa."
    }
    $passwords = @{}
    foreach ($name in @('Course-Server1', 'Course-Server2', 'Course-Client')) {
        if ($AdoptedVMs.ContainsKey($name)) { continue }
        $secure = Read-Host "Yllapitajasalasana virtuaalikoneelle $name" -AsSecureString
        $plain = ConvertTo-PlainText $secure
        if ($plain.Length -lt 12 -or $plain -notmatch '[a-z]' -or $plain -notmatch '[A-Z]' -or
            $plain -notmatch '\d' -or $plain -notmatch '[^a-zA-Z0-9]') {
            throw 'Salasanan tulee olla vahintaan 12 merkkia ja sisaltaa pieni ja iso kirjain, numero seka erikoismerkki.'
        }
        $passwords[$name] = $plain
    }
    $neededRam = 2 * $serverMemory + $clientMemory + 4096
    if ($facts.FreeMemoryGB * 1024 -lt $neededRam) {
        Write-Warning "VM:ien muisti ja 4 GiB host-varaus ylittavat vapaan muistin. Kaytto voi olla hidasta."
    }
    [pscustomobject]@{
        Platform = $Platform
        AdoptedVMs = $AdoptedVMs
        Network = $network
        Dns = $dns
        ServerIso = @($serverIso1, $serverIso2)
        ClientIso = $clientIso
        ServerIndex = @($serverIndex1, $serverIndex2)
        ClientIndex = $clientIndex
        ServerMemory = $serverMemory
        ClientMemory = $clientMemory
        ServerCpu = $serverCpu
        ClientCpu = $clientCpu
        ServerDisk = $serverDisk
        ClientDisk = $clientDisk
        FreeSpaceGB = [math]::Floor($freeSpaceGB)
        GuestCredentials = $passwords
    }
}

function Save-Manifest {
    param([hashtable]$Config)
    $directoryAlreadyExisted = Test-Path -LiteralPath $script:LabRoot
    if (-not (Test-Path -LiteralPath $script:LabRoot)) {
        New-Item -ItemType Directory -Path $script:LabRoot | Out-Null
        Set-PrivateAcl $script:LabRoot
    }
    $safe = [ordered]@{
        ManifestVersion = 2
        Platform = $Config.Platform
        Network = $Config.Network
        Dns = $Config.Dns
        ServerIso = $Config.ServerIso
        ClientIso = $Config.ClientIso
        LabDirectoryAdopted = $directoryAlreadyExisted
        NatAdopted = $true
        SwitchAdopted = $true
        OriginalNat = $null
        GatewayAddressCreated = $false
        Created = (Get-Date).ToString('o')
        VMs = @()
        Notice = 'Installation answer files can contain local administrator passwords.'
    }
    $safe | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:ManifestPath -Encoding UTF8
    Set-PrivateAcl $script:ManifestPath
}

function Assert-LabFilePathsAvailable {
    param([hashtable]$AdoptedVMs)
    if (-not (Test-Path -LiteralPath $script:LabRoot -PathType Container)) { return }
    $entries = @(Get-ChildItem -LiteralPath $script:LabRoot -Force -ErrorAction Stop)
    foreach ($name in @('Course-Server1', 'Course-Server2', 'Course-Client')) {
        if ($AdoptedVMs.ContainsKey($name)) { continue }
        $reserved = @($name, "$name.vdi", "$name-answer", "$name-answer.iso", "$name.password")
        $conflicts = @($entries | Where-Object {
            $_.Name -in $reserved -or $_.Name.StartsWith("$name-unattended", [StringComparison]::OrdinalIgnoreCase)
        })
        if ($conflicts.Count) {
            throw "Lab-hakemistossa on jo VM:n $name kayttamia tiedostopolkuja: $($conflicts.Name -join ', '). Niita ei korvata."
        }
    }
}

function Select-AdoptedVMs {
    param([ValidateSet('Hyper-V', 'VirtualBox')][string]$Platform)
    $inventory = if ($Platform -eq 'Hyper-V') { @($script:HyperVVmInventory) } else { @($script:VBoxVmInventory) }
    $adoptions = @{}
    $usedIds = @{}
    $roles = @(
        @{ Name = 'Course-Server1'; Pattern = 'Windows.*2019|Windows2019' },
        @{ Name = 'Course-Server2'; Pattern = 'Windows.*2019|Windows2019' },
        @{ Name = 'Course-Client'; Pattern = 'Windows.*11|Windows11' }
    )
    foreach ($role in $roles) {
        $candidates = @($inventory | Where-Object {
            $_.Name -eq $role.Name -or $_.OS -match $role.Pattern
        } | Where-Object { -not $usedIds.ContainsKey($_.Id) })
        if (-not $candidates.Count) { continue }
        Write-Host "`nVM-kandidaatit roolille $($role.Name) (olemassa olevia levyja tai kayttojarjestelmaa ei alusteta):"
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $candidate = $candidates[$i]
            Write-Host ("{0}) {1} | OS={2} | tila={3} | CPU={4} | RAM={5} MB | verkko={6}" -f
                ($i + 1), $candidate.Name, $candidate.OS, $candidate.State, $candidate.CPU, $candidate.MemoryMB,
                $(if ($Platform -eq 'Hyper-V') { $candidate.Switch } else { $candidate.Adapter1 }))
        }
        $choice = Read-Host "Adoptoi VM rooliksi $($role.Name)? Syota numero tai Enter luo uuden VM:n"
        if (-not $choice) { continue }
        $index = 0
        if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $candidates.Count) {
            throw "Virheellinen VM-valinta roolille $($role.Name)."
        }
        $selected = $candidates[$index - 1]
        if ($selected.State -ne 'poweroff' -and [string]$selected.State -ne 'Off') {
            throw "VM $($selected.Name) ei ole sammutettu. Sammuta se ennen adoptointia; muita muutoksia ei tehty."
        }
        if ($role.Name -eq 'Course-Client' -and $Platform -eq 'VirtualBox' -and
            ($selected.Firmware -ne 'EFI' -or $selected.TpmType -ne '2.0')) {
            throw "VM $($selected.Name) ei nayta Windows 11:n vaatimaa EFI/TPM 2.0 -kokoonpanoa. Sita ei adoptoida automaattisesti."
        }
        $adoptions[$role.Name] = $selected
        $usedIds[$selected.Id] = $true
    }
    return $adoptions
}

function Remove-Lab {
    if (-not (Test-IsAdministrator)) { throw 'Labin poisto vaatii jarjestelmanvalvojan PowerShell-istunnon.' }
    if (-not (Test-Path -LiteralPath $script:ManifestPath)) { throw "Manifestia ei loytynyt: $script:ManifestPath" }
    $manifest = Get-Content -LiteralPath $script:ManifestPath -Raw | ConvertFrom-Json
    if ($manifest.Platform -notin @('Hyper-V', 'VirtualBox')) {
        throw "Manifestin alusta on virheellinen: $($manifest.Platform). Resursseja ei poisteta."
    }
    $networkOwnershipKnown = $manifest.PSObject.Properties['ManifestVersion'] -and $manifest.ManifestVersion -eq 2
    if (-not $networkOwnershipKnown) {
        Write-Warning 'Vanhan manifestin verkkojen omistustietoa ei voi varmistaa. Verkkoasetukset ja manifesti sailytetaan kasin tarkistettaviksi.'
    }
    Write-Host "Poistetaan vain manifestin lab-resurssit alustalta $($manifest.Platform). Lab-hakemisto: $script:LabRoot"
    if (-not (Confirm-Change 'Poisto pysayttaa ja poistaa skriptin luomat VM-rekisteroinnit ja lab-verkot. Adoptoidut VM:t sailytetaan ja niiden alkuperaiset asetukset palautetaan. Lab-hakemisto ja levyt sailytetaan kasin tarkistettaviksi.')) {
        throw 'Kayttaja peruutti poiston.'
    }
    $managedIds = @($manifest.VMs | ForEach-Object { ([guid]$_.Id).ToString('D') })
    if ($manifest.Platform -eq 'Hyper-V') {
        $nat = @(Get-NetNat -ErrorAction Stop) | Where-Object Name -eq $script:HyperVNat
        if ($nat -and $nat.InternalIPInterfaceAddressPrefix -ne $manifest.Network.Prefix) {
            throw 'WinNAT-verkon osoitealue poikkeaa manifestista; resursseja ei poisteta.'
        }
        $switches = @(Get-VMSwitch -ErrorAction Stop)
        $switch = $switches | Where-Object Name -eq $script:HyperVSwitch
        $knownVms = @(Get-VM -ErrorAction Stop)
        if ($switch -and $switch.SwitchType -ne 'Internal') {
            throw 'Hyper-V-kytkimen tyyppi poikkeaa manifestin mukaisesta; resursseja ei poisteta.'
        }
        if ($networkOwnershipKnown -and $switch -and (-not $manifest.SwitchAdopted -or -not $manifest.NatAdopted -or $manifest.GatewayAddressCreated)) {
            foreach ($vm in $knownVms) {
                if (([guid]$vm.Id).ToString('D') -in $managedIds) { continue }
                if (Get-VMNetworkAdapter -VM $vm -ErrorAction Stop | Where-Object SwitchName -eq $script:HyperVSwitch) {
                    throw "VM $($vm.Name) kayttaa lab-kytkinta, mutta ei kuulu manifestiin. Resursseja ei poisteta."
                }
            }
        }
        foreach ($record in $manifest.VMs | Where-Object Adopted) {
            $vm = $knownVms | Where-Object { [guid]$_.Id -eq [guid]$record.Id }
            if ($vm -and $vm.State -ne 'Off') { throw "Adoptoitu VM $($vm.Name) on kaynnissa. Sammuta se ennen poistoa." }
            if ($vm -and $record.Original.SwitchName -and
                -not ($switches | Where-Object Name -eq $record.Original.SwitchName)) {
                throw "Adoptoidun VM:n $($vm.Name) alkuperaista kytkinta $($record.Original.SwitchName) ei loydy. Resursseja ei poisteta."
            }
        }
        foreach ($record in $manifest.VMs) {
            $vm = $knownVms | Where-Object { [guid]$_.Id -eq [guid]$record.Id }
            if ($vm) {
                if ($record.Adopted) {
                    if ($vm.State -ne 'Off') {
                        throw "Adoptoitu VM $($vm.Name) on kaynnissa. Sammuta se ennen labin poistoa, jotta alkuperaiset asetukset voidaan palauttaa."
                    }
                    $original = $record.Original
                    Set-VMProcessor -VM $vm -Count $original.CPU
                    Set-VMMemory -VM $vm -StartupBytes $original.MemoryStartup `
                        -DynamicMemoryEnabled $original.DynamicMemoryEnabled `
                        -MinimumBytes $original.MemoryMinimum -MaximumBytes $original.MemoryMaximum
                    $adapter = Get-VMNetworkAdapter -VM $vm
                    if ($original.SwitchName) {
                        Connect-VMNetworkAdapter -VMNetworkAdapter $adapter -SwitchName $original.SwitchName
                    }
                    else { Disconnect-VMNetworkAdapter -VMNetworkAdapter $adapter }
                    continue
                }
                if ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff -Confirm:$false }
                Remove-VM -VM $vm -Force
            }
        }
        if ($networkOwnershipKnown -and -not $manifest.NatAdopted -and $nat) {
            $nat | Remove-NetNat -Confirm:$false
        }
        if ($networkOwnershipKnown -and $manifest.SwitchAdopted -and $manifest.GatewayAddressCreated) {
            $adapter = Get-NetAdapter -Name "vEthernet ($script:HyperVSwitch)" -ErrorAction SilentlyContinue
            if ($adapter) {
                Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object IPAddress -eq $manifest.Network.Gateway |
                    Remove-NetIPAddress -Confirm:$false
            }
        }
        if ($networkOwnershipKnown -and -not $manifest.SwitchAdopted -and $switch) {
            $switch | Remove-VMSwitch -Force -Confirm:$false
        }
    }
    else {
        $natList = (& (Get-VBoxManage) list natnets 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "VirtualBox NAT-verkkojen luku epaonnistui: $natList" }
        $natPattern = '(?ms)^\s*(?:NetworkName|Name):\s+{0}\s*$([\s\S]*?)(?=^\s*(?:NetworkName|Name):|\z)' -f [regex]::Escape($script:VBoxNat)
        $natEntry = [regex]::Match($natList, $natPattern)
        if ($natEntry.Success -and $natEntry.Groups[1].Value -notmatch "(?m)^\s*Network:\s+$([regex]::Escape($manifest.Network.Prefix))\s*$") {
            throw 'VirtualBox NAT-verkon osoitealue poikkeaa manifestista; resursseja ei poisteta.'
        }
        $originalNat = if ($manifest.PSObject.Properties['OriginalNat']) { $manifest.OriginalNat } else { $null }
        if ($networkOwnershipKnown -and $natEntry.Success -and (-not $manifest.NatAdopted -or $originalNat)) {
            $foreign = @($script:VBoxVmInventory | Where-Object {
                $_.NatNetworks -contains $script:VBoxNat -and ([guid]$_.Id).ToString('D') -notin $managedIds
            })
            if ($foreign.Count) { throw "VirtualBox NAT-verkkoa kayttaa labin ulkopuolinen VM: $($foreign.Name -join ', '). Resursseja ei poisteta." }
        }
        foreach ($record in $manifest.VMs) {
            $list = (& (Get-VBoxManage) list vms 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0) { throw "VirtualBox VM-listan luku epaonnistui: $list" }
            if ($list -match [regex]::Escape($record.Id)) {
                if ($record.Adopted) {
                    $adoptedInfo = (& (Get-VBoxManage) showvminfo $record.Id --machinereadable 2>&1) -join "`n"
                    if ($LASTEXITCODE -ne 0) { throw "Adoptoidun VirtualBox VM:n tietojen luku epaonnistui: $adoptedInfo" }
                    if ($adoptedInfo -notmatch '(?m)^VMState="poweroff"$') {
                        throw "Adoptoitu VM $($record.Name) on kaynnissa. Sammuta se ennen labin poistoa asetusten palauttamiseksi."
                    }
                    $original = $record.Original
                    $arguments = @('modifyvm', $record.Id, '--cpus', [string]$original.CPU, '--memory', [string]$original.MemoryMB, '--nic1', [string]$original.NicType)
                    switch ([string]$original.NicType) {
                        'natnetwork' { $arguments += @('--nat-network1', [string]$original.NatNetwork) }
                        'bridged' { $arguments += @('--bridge-adapter1', [string]$original.BridgeAdapter) }
                        'hostonly' { $arguments += @('--host-only-adapter1', [string]$original.HostOnlyAdapter) }
                        'intnet' { $arguments += @('--intnet1', [string]$original.InternalNetwork) }
                    }
                    if ($null -ne $original.CableConnected) { $arguments += @('--cableconnected1', [string]$original.CableConnected) }
                    if ($original.NicType -eq 'generic' -and $original.GenericDriver) {
                        $arguments += @('--nic-generic-drv1', [string]$original.GenericDriver)
                    }
                    Invoke-VBox $arguments
                    continue
                }
                $info = (& (Get-VBoxManage) showvminfo $record.Id --machinereadable 2>&1) -join "`n"
                if ($LASTEXITCODE -ne 0) { throw "VirtualBox VM:n tietojen luku epaonnistui: $info" }
                $stateMatch = [regex]::Match($info, '(?m)^VMState="([^"]+)"$')
                if (-not $stateMatch.Success) { throw "VirtualBox VM:n $($record.Name) tilaa ei saatu selville." }
                if ($stateMatch.Groups[1].Value -eq 'saved') {
                    Invoke-VBox @('discardstate', $record.Id)
                }
                elseif ($stateMatch.Groups[1].Value -ne 'poweroff') {
                    Invoke-VBox @('controlvm', $record.Id, 'poweroff')
                }
                Invoke-VBox @('unregistervm', $record.Id)
            }
        }
        if ($networkOwnershipKnown -and $natEntry.Success -and $manifest.NatAdopted -and $originalNat) {
            $dhcpOption = if ($originalNat.DhcpEnabled) { 'on' } else { 'off' }
            Invoke-VBox @('natnetwork', 'modify', '--netname', $script:VBoxNat,
                '--network', [string]$originalNat.Network, '--dhcp', $dhcpOption)
        }
        if ($networkOwnershipKnown -and $natEntry.Success -and -not $manifest.NatAdopted) {
            try { Invoke-VBox @('natnetwork', 'stop', '--netname', $script:VBoxNat) }
            catch { Write-Warning "NAT-verkon pysaytys ilmoitti virheen; poistoa yritetaan silti: $($_.Exception.Message)" }
            Invoke-VBox @('natnetwork', 'remove', '--netname', $script:VBoxNat)
        }
    }
    if ($networkOwnershipKnown) { Remove-Item -LiteralPath $script:ManifestPath -Force }
    Write-Warning "Lab-hakemisto ja sen tiedostot (myos virtuaalilevyt ja mahdollisia salasanoja sisaltavat vastaustiedostot) sailytetaan: $script:LabRoot. Tarkista ja poista tarpeettomat tiedostot kasin."
    if ($networkOwnershipKnown) {
        Write-Host 'Labin VM-rekisteroinnit ja hallitut verkkoasetukset poistettu tai palautettu.'
    }
    else {
        Write-Host 'Labin VM-rekisteroinnit on kasitelty. Verkkoasetukset ja manifesti vaativat manuaalisen tarkistuksen.'
    }
}

function Test-NetworkCalculations {
    $range = Get-NetworkRange '192.168.252.33/24'
    if ($range.Network -ne '192.168.252.0' -or $range.End -ne (ConvertTo-IPv4Number '192.168.252.255')) {
        throw 'IPv4-verkon laskennan itsetarkistus epaonnistui.'
    }
    $network = Get-IPv4Addresses '192.168.252.0/24'
    if ($network.Gateway -ne '192.168.252.1' -or $network.Guests[0] -ne '192.168.252.10') {
        throw 'Lab-verkon osoitteiden itsetarkistus epaonnistui.'
    }
    $publicRangeRejected = $false
    try { Get-IPv4Addresses '8.8.8.0/24' | Out-Null }
    catch { $publicRangeRejected = $true }
    if (-not $publicRangeRejected) { throw 'Julkisen IPv4-alueen esto-itsetarkistus epaonnistui.' }
}

try {
    Write-Host 'Windows-kurssiymparisto. Tarkistus ei muuta hostia.'
    Write-Host "Toiminto: $Action"
    Write-Host "Microsoft Windows 11 ISO: https://www.microsoft.com/software-download/windows11"
    Write-Host "Windows Server arviointiversiot: https://www.microsoft.com/evalcenter/"
    Write-Host 'Kayta vain mediaa, johon sinulla on oikeus.'
    Write-HostReport
    Write-PlatformInventory

    if ($Action -eq 'Check') {
        Test-NetworkCalculations
        Write-Host 'Sisainen verkko-osoitteiden itsetarkistus onnistui.'
        Write-Host "`nTarkistus valmis. Deployment: .\New-WindowsCourseLab.ps1 -Action Deploy"
        exit 0
    }
    if ($Action -eq 'Remove') {
        Remove-Lab
        exit 0
    }

    if (Test-Path -LiteralPath $script:ManifestPath) {
        throw "Lab-manifesti on jo olemassa: $script:ManifestPath. Kayta olemassa olevaa labia tai poista se erikseen ennen uutta kayttoonottoa."
    }
    Write-Host "`nValitse yksi virtualisointialusta:"
    Write-Host '1) Hyper-V'
    Write-Host '2) VirtualBox'
    $platformChoice = Read-Host 'Valinta (1/2), muu keskeyttaa'
    $platform = switch ($platformChoice) { '1' { 'Hyper-V' } '2' { 'VirtualBox' } default { throw 'Alustaa ei valittu.' } }
    Assert-PlatformPrerequisites $platform
    $adoptedVMs = Select-AdoptedVMs $platform
    if ($platform -eq 'Hyper-V' -and $adoptedVMs.Count -lt 3) { Resolve-HyperVAnswerTool }
    Initialize-Platform $platform
    $config = Read-DeploymentConfig $platform $adoptedVMs
    $config = @{
        Platform = $config.Platform; Network = $config.Network; Dns = $config.Dns
        ServerIso = $config.ServerIso; ClientIso = $config.ClientIso
        ServerIndex = $config.ServerIndex; ClientIndex = $config.ClientIndex
        ServerMemory = $config.ServerMemory; ClientMemory = $config.ClientMemory
        ServerCpu = $config.ServerCpu; ClientCpu = $config.ClientCpu
        ServerDisk = $config.ServerDisk; ClientDisk = $config.ClientDisk
        GuestCredentials = $config.GuestCredentials; AdoptedVMs = $config.AdoptedVMs
    }
    Test-LabResourceConflicts $platform $config.Network.Prefix $config.AdoptedVMs
    Assert-LabFilePathsAvailable $config.AdoptedVMs
    if (Test-Path -LiteralPath $script:LabRoot) {
        Write-Warning "Lab-hakemisto on jo olemassa: $script:LabRoot. Sen muita tiedostoja ei korvata."
        if (-not (Confirm-Change 'Lab-hakemisto on ennestaan olemassa. Jatkettaessa siihen lisataan lab.json ja vain puuttuvat VM-tiedostot.')) {
            throw 'Kayttaja peruutti olemassa olevan lab-hakemiston kayton.'
        }
        if ($config.AdoptedVMs.Count -lt 3) { Assert-PrivateDirectory $script:LabRoot }
    }
    Write-Host "`nValittu alusta: $platform"
    Write-Host "Verkko: $($config.Network.Prefix), yhdyskaytava: $($config.Network.Gateway), DNS: $($config.Dns)"
    Write-Host "VM:t: palvelimet $($config.ServerCpu) vCPU/$($config.ServerMemory) MB/$($config.ServerDisk) GiB; tyokone $($config.ClientCpu) vCPU/$($config.ClientMemory) MB/$($config.ClientDisk) GiB."
    Write-Host 'Huom: staattiset IP-asetukset tehdaan Windowsin valvomattoman asennuksen aikana.'
    Write-Host 'Salasanat sisaltyvat asennuksen vastaustietoihin. Lab-hakemisto tulee suojata.'
    if ($platform -eq 'Hyper-V' -and $config.AdoptedVMs.Count -lt 3) {
        Write-Host 'Hyper-V: VM-tunnuksille lisataan lukuoikeus asennus-ISOihin. Oikeudet ja lab-tiedostot jaavat poistossa tarkistettaviksi.'
    }
    $adoptedNames = @($config.AdoptedVMs.Keys)
    if ($adoptedNames.Count) {
        Write-Host "Olemassa olevat VM:t: $($adoptedNames -join ', '). Niiden virtuaalilevyja ja kayttojarjestelmaa ei alusteta, ja niiden levykoon valinta ohitetaan; isantatason CPU-, muisti- ja verkkokorttiasetuksia voidaan muuttaa erillisella vahvistuksella. Vieraskayttojarjestelman IP-asetukset on tarkistettava kasin."
    }
    if (-not (Confirm-Change "Luodaan puuttuvat VM:t ja lab-verkko alustalla $platform seka liitetaan mahdolliset adoptoitavat VM:t. Muutokset kuluttavat hostin resursseja ja voivat katkaista adoptoitavan VM:n nykyisen verkkoyhteyden.")) {
        throw 'Kayttaja peruutti labin luonnin.'
    }
    Save-Manifest $config
    if ($platform -eq 'Hyper-V') { New-HyperVEnvironment $config } else { New-VBoxEnvironment $config }
    Write-Host "`nKayttoonotto kaynnistetty. Uudet VM:t suorittavat valvomatonta asennusta; adoptoidut VM:t jatkavat olemassa olevalla kayttojarjestelmalla sammutettuina."
    Write-Host "Lab-tiedostot ja mahdolliset asennuksen vastaustiedostot ovat: $script:LabRoot"
    Write-Host "Tarkista VM-konsolit asennuksen etenemisen seuraamiseksi. Poisto: .\New-WindowsCourseLab.ps1 -Action Remove"
}
catch {
    if ($_.ScriptStackTrace) { Write-Host "Virheen sijainti:`n$($_.ScriptStackTrace)" }
    Write-Error $_
    exit 1
}
