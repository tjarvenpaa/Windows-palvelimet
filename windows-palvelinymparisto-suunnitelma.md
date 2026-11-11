# Windows-palvelinympäristö kurssikäyttöön – toteutusehdotus

## Tavoite

Luoda Windows 11 -hostilla opiskelijan hallittavissa oleva, toisistaan eristetty virtuaalinen kurssiympäristö, jossa on:

- kaksi Windows Server 2019 -virtuaalikonetta
- yksi Windows 11 -virtuaalityöasema
- yhteinen yksityinen virtuaaliverkko
- virtuaalikoneille ulospäin toimiva internet-yhteys NATin kautta
- ei oletusarvoista sisääntulevaa yhteyttä internetistä virtuaalikoneisiin

## Suositeltu toteutustapa

Suosittelen aloittamaan PowerShell-pohjaisella käyttöönotto-ohjelmalla Terraformin sijaan. Ohjelma toimii Windows 11:llä suoraan, tarkistaa hostin vaatimukset, kartoittaa molempien alustojen nykyiset asetukset ja pyytää valitsemaan virtualisointialustan ennen ympäristön luontia. Samannimisiä tai muuten valittuja resursseja voidaan adoptoida vain, kun asetuserot näytetään ja käyttäjä vahvistaa muutokset erikseen. Vieraslevyjä ja käyttöjärjestelmää ei alusteta adoptoitaessa.

Terraform on mahdollinen vaihtoehto, mutta se tarvitsee tässä ympäristössä alustakohtaisen providerin ja sen asennuksen/hallinnan. Se ei itsessään ota Windowsin hypervisoria käyttöön. Opiskelijan Windows-koneessa PowerShell mahdollistaa hostin tarkistukset ja Windowsin ominaisuuksien hallinnan samassa käyttökulussa. Terraformia voidaan arvioida myöhemmin, jos kurssilla halutaan erityisesti harjoitella Terraformia tai valittu provider on hyväksytty.

## Käyttöpolku

1. **Esitarkistus ilman muutoksia:** tunnista Windows-versio ja -versiojulkaisu, järjestelmän arkkitehtuuri, järjestelmänvalvojan oikeudet, virtualisoinnin tila, levytila, muisti, alustojen ominaisuudet, virtuaalikytkimet/NAT-verkot sekä VM:ien nimet, tila, OS-tyyppi ja keskeiset resurssi- ja verkkokorttiasetukset. Hyper-V:n yksityiskohtainen inventaario vaatii korotetun istunnon.

   Hyper-V-inventaariossa vieraskäyttöjärjestelmä merkitään tuntemattomaksi: siinä adoptointiehdokkaat tunnistetaan vain VM:n täsmällisen lab-roolinimen perusteella. Käyttäjän on itse varmistettava vieraskäyttöjärjestelmän sopivuus ennen adoptointia. VirtualBoxin ilmoittamaa OS-tyyppiä käytetään lisäksi sen ehdokkaiden etsimiseen.
2. **Näytä tulos:** erottele ehdottomat estot ja varoitukset. Jos host ei täytä valitun alustan ehtoja, älä jatka VM:ien luontiin.
3. **Valinta:** tarjoa käyttäjälle Hyper-V, VirtualBox tai keskeytys. Näytä alustakohtaiset vaatimukset ja toimenpiteet ennen valinnan vahvistamista.
4. **Host-muutosten erillinen hyväksyntä:** ennen ominaisuuden käyttöönottoa tai ohjelmiston asennusta näytä täsmälleen tehtävä muutos, sen vaikutukset ja mahdollinen uudelleenkäynnistys. Älä tee muutoksia ilman käyttäjän nimenomaista hyväksyntää. Keskeytä, jos hyväksyntä puuttuu.
5. **Ympäristön määritys:** käytä skriptin vieressä olevia `server.iso`- ja `win11.iso`-tiedostoja tai pyydä puuttuvien paikallisten asennusmedioiden polut. Tarkista vapaa levytila lab-hakemiston sisältävän levyn osalta. VM-tiedostot sijoitetaan skriptin viereen omaan `WindowsCourseLab`-hakemistoon.
6. **Käyttöönotto:** luo kolme VM:ää ja suljettu virtuaaliverkko, kytke VM:t siihen, määritä verkko ja käynnistä asennukset.
7. **Yhteenveto ja poisto-ohje:** raportoi luodut resurssit, osoitteet, verkon toimintatapa, mahdolliset uudelleenkäynnistykset ja tapa poistaa vain tämän ympäristön resurssit.

## Verkkoratkaisu

Kummallekin alustalle luodaan oma virtuaalinen sisäverkko, johon kaikki kolme VM:ää liitetään. NAT sallii VM:ien ulospäin aloittamat yhteydet internetiin; sisääntulevia porttiohjauksia ei määritetä oletuksena.

- **Hyper-V:** luodaan sisäinen virtuaalikytkin ja sille NAT. WinNAT ei itsessään jaa VM:ille osoitteita, DNS-palvelinta tai oletusyhdyskäytävää, joten suunnitelmaan kuuluu osoitteiden ja verkkoasetusten määritys. Verkon osoitealue tarkistetaan ensin hostin nykyisiä verkkoja vasten.
- **VirtualBox:** käytetään yhteistä NAT Network -verkkoa (ei erillistä yksittäisen VM:n NAT-tilaa), jotta koneet voivat kommunikoida keskenään ja samalla käyttää NAT-yhteyttä.

NAT ei yksinään takaa, ettei vierasverkosta pääse hostiin tai ettei VM:n sisältä voi ottaa yhteyksiä muihin verkkoihin. VirtualBoxin NAT-verkossa vieras voi lisäksi tavoittaa hostin loopback-palveluita. Toteutuksen tulee dokumentoida tämä raja, välttää porttiohjauksia ja tarkistaa verkkoasetukset. Hostin palomuuria tai reitittimen asetuksia ei muuteta tässä suunnitelmassa.

## Hostin lähtövaatimukset ja onnistumiseen vaikuttavat tekijät

### Ehdottomat tai alustakohtaiset vaatimukset

- Tuettu 64-bittinen Windows 11 -host ja yhteensopiva x64-prosessori, jossa laitteistovirtualisointi ja SLAT ovat käytettävissä. Virtualisoinnin pitää olla sallittu myös UEFI/BIOS-asetuksissa.
- **Hyper-V:** Windows 11 Pro, Enterprise tai Education (ei Home), riittävä laitteisto ja järjestelmänvalvojan oikeudet ominaisuuden käyttöönottoon. Käyttöönotto voi vaatia uudelleenkäynnistyksen.
- **VirtualBox:** tuettu VirtualBox-asennuspaketti ja järjestelmänvalvojan oikeudet asennukseen. Windowsin Hyper-V/VBS-ominaisuudet voivat vaikuttaa suorituskykyyn tai yhteensopivuuteen; VirtualBoxin Hyper-V-pohjainen toimintatapa on dokumentoitu rajoitteineen.
- Laillisesti käytettävät Windows Server 2019- ja Windows 11 -asennusmediat sekä lisenssit tai soveltuvat arviointiversiot. Skripti ei sisällä Windows-asennusmedioita eikä ohita lisensointia.
- Riittävästi vapaata levytilaa kolmelle virtuaalilevylle ja asennusmedioille sekä riittävästi RAM-muistia hostille ja kolmelle VM:lle. Skripti varoittaa, jos lab-levyn vapaa tila alittaa virtuaalilevyjen yhteenlasketun enimmäiskoon; dynaamiset levyt kasvavat käytössä, joten varoitus ei ole asennuksen vähimmäistilavaatimus.
- Yksityinen IP-osoitealue, joka ei ole päällekkäinen hostin aktiivisten VPN-, LAN- tai muiden virtuaaliverkkojen kanssa.

### Käyttöön vaikuttavat tekijät

- Windowsin Home/Pro/Enterprise/Education-versio, käyttöjärjestelmän päivitystaso, UEFI/BIOS-asetukset, Secure Boot/VBS sekä nykyiset virtualisointikomponentit.
- Yrityksen tai oppilaitoksen laitehallinta- ja suojauskäytännöt voivat estää ominaisuuksien aktivoinnin, ajurien asennuksen, skriptien suorittamisen tai järjestelmänvalvojan oikeudet.
- VPN-ohjelmistot, Hyper-V, Windows Sandbox, WSL2, Docker ja muut hypervisorit/verkkosuodattimet voivat vaikuttaa verkkoon tai suorituskykyyn.
- Internet-yhteyden palomuuri/proxy, DNS ja aktivointipalvelut voivat estää Windowsin asennuksen tai päivitykset.
- Verkon DHCP/NAT ei saa olla ristiriidassa hostin muiden verkkojen kanssa. Hyper-V:n WinNAT-verkon IP-asetus ei ole sama asia kuin automaattinen DHCP.
- VM:n nimet, tallennussijainti, asennusmedian kieli/versio, lisenssi, haluttu palvelinrooli sekä halutaanko koneiden nimetä ja perusasetukset tehdä automaattisesti vai asennusvaiheessa käsin.

### Kapasiteetin lähtöarvot

Skriptin oletukset ovat palvelimille 2 vCPU, 4 GiB RAM ja 80 GiB dynaaminen virtuaalilevy sekä työasemalle 2 vCPU, 8 GiB RAM ja 80 GiB dynaaminen virtuaalilevy. Käyttäjä näkee ja voi muuttaa arvoja ennen VM:ien luontia. Dynaaminen levy kasvaa käytön mukaan, joten 80 GiB on virtuaalilevyn enimmäiskoko, ei heti varattu host-tila. Tarkistus varoittaa niukasta RAM- tai levytilasta mutta ei takaa suorituskykyä.

## Vaikutukset host-koneeseen

Skriptin esitarkistus ei muuta hostia. Ympäristön luonnin yhteydessä tehtävät host-muutokset riippuvat valitusta alustasta:

- Hyper-V:n käyttöönotto lisää Windowsin valinnaisen virtualisointikomponentin ja käynnistää hypervisorin Windowsin käynnistyksen yhteydessä. Tämä voi vaatia uudelleenkäynnistyksen ja vaikuttaa VirtualBoxin tai muiden hypervisorien toimintaan sekä VBS-/WSL2-/Docker-kokoonpanoihin.
- VirtualBoxin asennus lisää virtualisointiohjelmiston ja verkkokomponentteja/ajureita. Se voi vaatia järjestelmänvalvojan oikeudet, vaikuttaa verkkosovittimien käsittelyyn ja aiheuttaa uudelleenkäynnistystarpeen.
- Molemmat vaihtoehdot kuluttavat hostin levytilaa, muistia ja prosessoria VM:ien ollessa käynnissä. VM-levyt voivat kasvaa käytön myötä.
- Sisäisen virtuaaliverkon/NATin luonti lisää hostiin virtuaalisen verkkosovittimen ja reitityksen. Osoitealueiden ristiriidat voivat katkaista tai ohjata liikennettä väärin.

Skripti ei muuta hostin BIOS/UEFI-asetuksia, Windowsin palomuurisääntöjä, reititintä tai VPN-asetuksia. `Check` ei muuta konetta. Deployment voi käyttäjän erillisellä vahvistuksella muuttaa valitun, sammutetun VM:n vCPU-, muisti- ja verkkokorttiasetuksia. Adoptoidun VM:n alkuperäiset asetukset tallennetaan manifestiin, eikä sen levyä tai käyttöjärjestelmää poisteta; poisto palauttaa tallennetut host-tason asetukset. VM:n vieras-IP pitää tarkistaa/määrittää erikseen, koska olemassa olevan käyttöjärjestelmän sisäisiä asetuksia ei muuteta.

## Turvallisuus, virhetilanteet ja palautettavuus

- Skriptin `Check`-toiminto tekee vain luku -tarkistukset ja raportoi alustojen asetukset. Hyper-V:n tarkat verkko- ja VM-tiedot vaativat järjestelmänvalvojan istunnon.
- Jokaisesta hostia muuttavasta vaiheesta pyydetään erillinen hyväksyntä; oletuksena ei tehdä muutoksia eikä ladata asennusohjelmia.
- Salasanat kysytään ajon aikana, ja vastaustiedostot voivat sisältää ne. Hyper-V:n vastaus-ISO:t säilytetään; VirtualBoxin vastaustiedostoja säilytetään lab-hakemistossa. Uuden hakemiston käyttöoikeudet rajataan. Jos hakemisto oli jo olemassa ja luodaan uusia VM:iä, sen oikeudet tarkistetaan: muiden kuin nykyisen käyttäjän, SYSTEMin ja järjestelmänvalvojien sallitut oikeudet estävät käyttöönoton. Käyttäjä korjaa oikeudet tarvittaessa itse.
- Skripti ehdottaa nykyisestä OS-tyypistä pääteltyjä VM:iä adoptoitavaksi. Adoptointi vaatii erillisen vahvistuksen; VM:n on oltava sammutettu. Käyttöjärjestelmää ja virtuaalilevyjä ei muuteta, mutta CPU-, muisti- ja verkkokorttiasetuksia voidaan muuttaa.
- Hyper-V käyttää samannimistä, yhteensopivaa sisäistä kytkintä/WinNAT-verkkoa vain, jos se ei ole muiden VM:ien käytössä. Muut WinNAT-verkot estävät labin luonnin. VirtualBoxin samanniminen NAT Network voidaan adoptoida; osoitealueen tai DHCP-tilan muutos vaatii erillisen vahvistuksen, eikä verkkoa muuteta, jos muut VM:t käyttävät sitä. Päällekkäiset eri nimiset verkot estävät käyttöönoton.
- Poistotoiminto tunnistaa VM:t manifestiin tallennetuilla tunnisteilla, pyytää erillisen vahvistuksen, poistaa skriptin luomat VM-rekisteröinnit ja hallitut verkot sekä palauttaa adoptoitujen VM:ien tallennetut asetukset. Se ei poista virtuaalilevyjä eikä lab-hakemistoa: käyttäjä tarkistaa ja poistaa tarpeettomat tiedostot itse. Hakemistossa voi olla myös salasanoja sisältäviä vastaustiedostoja. Ulkopuolisten VM:ien verkkokytkennät estävät verkon poiston tai palautuksen.
- Virhe keskeyttää työn virheilmoitukseen. Jo luodut resurssit voivat jäädä osittaisen virheen jälkeen; manifesti säilytetään, jotta poisto voidaan käynnistää erikseen.

## Hyväksytyt toteutusrajaukset

Suunnitelma hyväksyttiin toteutuksen pohjaksi seuraavin valinnoin:

- Skripti tukee Hyper-V:tä ja VirtualBoxia, mutta käyttäjä valitsee ajon aikana yhden alustan. Skripti ei asenna tai ota käyttöön molempia.
- Skripti voi ottaa valitun alustan käyttöön/asentaa sen vain erillisen, ennen kyseistä muutosta näytettävän vahvistuksen jälkeen. VirtualBox-asennin hankitaan virallisesta lähteestä ja käyttäjä osoittaa paikallisen asennustiedoston.
- Skripti avaa Microsoftin viralliset lataussivut; opiskelija hankkii ja valitsee itse ISO-tiedostot.
- Käyttöönotossa skriptin vieressä oleva `server.iso` käytetään molemmille uusille palvelimille ja `win11.iso` uudelle työasemalle. Jos kyseistä tiedostoa ei ole, polku kysytään erikseen kullekin uudelle VM:lle. Adoptoidulle VM:lle ei tarvita ISOa. Lähtöoletuksena mediat ovat Evaluation-lisenssillä; skripti ei kysy eikä määritä tuoteavaimia. Käyttäjä valitsee asennuskuvan ISO:n sisältämistä vaihtoehdoista.
- Virtuaalikoneiden ja vastaustiedostojen tallennussijainti on skriptin vieressä oleva `WindowsCourseLab`-hakemisto. Jos hakemisto on jo olemassa, skripti pyytää vahvistuksen, tarkistaa oikeudet sekä suunniteltujen tiedostopolkujen mahdolliset ristiriidat eikä korvaa tiedostoja.
- Ensimmäinen versio käyttää staattisia verkkoasetuksia. DHCP:tä ei oteta käyttöön.
- Windows-asennus tehdään valvomattomasti. Salasana kysytään ajon aikana. Hyper-V:n vastaustiedosto-ISO luodaan Windows ADK:n `oscdimg.exe`-työkalulla; skripti ei asenna ADK:ta.
- Vastaustiedostot säilytetään asennuksen jälkeen mahdollista uudelleenasennusta varten. Ne voivat sisältää asennuksessa käytetyn ylläpitäjäsalasanan, joten lab-hakemisto on arkaluonteinen. Skripti rajaa hakemiston käyttöoikeudet; käyttäjä vastaa tiedostojen suojaamisesta ja poistamisesta, kun niitä ei enää tarvita.
- Palvelimille asennetaan vain Windows-peruskäyttöjärjestelmä. Palvelinroolit ja niiden asetukset rajataan myöhempään työhön.
- VM-resurssien määrät toteutetaan oletusarvoina, jotka käyttäjä voi tarkistaa/muuttaa ennen luontia. Hostin todellinen kapasiteetti tarkistetaan ajon aikana.

## Skriptin käyttö

Skriptin oletustoiminto on vain luku -esitarkistus:

```powershell
.\New-WindowsCourseLab.ps1 -Action Check
```

Ympäristön luonti käynnistetään korotetusta PowerShell-istunnosta:

```powershell
.\New-WindowsCourseLab.ps1 -Action Deploy
```

Poisto tunnistaa VM:t manifestiin tallennetuilla tunnisteilla ja vaatii erillisen vahvistuksen:

```powershell
.\New-WindowsCourseLab.ps1 -Action Remove
```

Poiston jälkeen virtuaalilevyt, vastaustiedostot ja muut lab-hakemiston tiedostot jäävät paikalleen, ja ne tulee tarkistaa sekä tarvittaessa poistaa käsin. Hyper-V lisää VM-tunnuksille lukuoikeudet käytettyihin asennus-ISOihin; nämä oikeudet jäävät myös poiston jälkeen ja ne voi tarvittaessa poistaa tiedostojen suojausasetuksista. Keskeytyneessä käyttöönotossa resurssi voi jäädä ilman manifestin omistustietoa, jolloin sitä ei poisteta automaattisesti vaan se on tarkistettava käsin.

Skriptin aiemmilla versioilla luodusta manifestista ei voi aina päätellä verkkoresurssien omistajuutta turvallisesti. Tällaisen manifestin poistossa verkot ja manifesti säilytetään, ja niiden tila pitää tarkistaa käsin. Uusi käyttöönotto estetään, kunnes vanha manifesti on asianmukaisen tarkistuksen jälkeen poistettu.

Deployment avaa Microsoftin lataussivut, mutta käyttäjä hankkii mediat itse. Skriptin vierestä tunnistetaan automaattisesti `server.iso` ja `win11.iso`; muutoin ISO-polut kysytään. Hyper-V:n Windows-asennus vaatii lisäksi Windows ADK:n `oscdimg.exe`-työkalun: skripti käyttää ensin viereistä tiedostoa, etsii sen sitten PATHista ja kysyy lopuksi tarvittaessa polun. Skripti ei asenna ADK:ta. VirtualBox-asennin valitaan paikallisena MSI-tiedostona virallisen lataussivun kautta. Skripti ei muuta PowerShellin suorituspolitiikkaa.

Viimeisin vain luku -esitarkistus havaitsi Windows 11 Education -hostin ja VirtualBox 7.2.22:n. Hyper-V-ominaisuus oli käyttäjän järjestelmänvalvojana ajamassa tarkistuksessa käytössä. `Win32_Processor`-kyselyn virtualisointi- ja SLAT-liput olivat `False`, mutta Windows ilmoitti aktiivisen hypervisorin; skripti käsittelee aktiivista hypervisoria virtualisointituen osoituksena eikä pysäytä käyttöönottoa näiden kahden CIM-lipun takia. Ei-korotettu tarkistus näytti VirtualBoxissa NAT-verkon `NatNetwork` (`192.168.10.0/24`, DHCP käytössä), VM:n `Windows server 1 ad-dc` (Windows Server 2019, 6 vCPU, 8192 MB, kyseisessä NAT-verkossa) sekä Linux-VM:n. Näitä ei muuteta, ellei opiskelija erikseen valitse VM:ää adoptoitavaksi.

## Lähteet

- Microsoft Learn: [Hyper-V:n asennus Windowsissa](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/get-started/Install-Hyper-V)
- Microsoft Learn: [Hyper-V:n laitteistovaatimukset](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/host-hardware-requirements)
- Microsoft Learn: [NAT-verkon määrittäminen Hyper-V:ssä](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/setup-nat-network)
- Oracle: [VirtualBox 7.2 User Guide](https://docs.oracle.com/en/virtualization/virtualbox/7.2/user/)
- Oracle: [VirtualBox NAT Network Service](https://docs.oracle.com/en/virtualization/virtualbox/7.2/user/networkingdetails.html)
