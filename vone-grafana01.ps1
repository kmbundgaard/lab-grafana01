# grafana01: upload the stock Rocky ISO + the OEMDRV answer-file ISO from vone (LAN), create the VM, let the
# unattended install power it off, detach both CDs, boot, wait for SSH. vCenter user/password on stdin only.
$ErrorActionPreference = 'Stop'
function Log { param($m) Write-Host ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $m) }
$u = [Console]::In.ReadLine(); $p = [Console]::In.ReadLine()
$cred = [pscredential]::new($u, (ConvertTo-SecureString $p -AsPlainText -Force)); Remove-Variable p
$b = 'C:\AutoDeploy-Build'
Import-Module VMware.VimAutomation.Core -WarningAction SilentlyContinue | Out-Null
Set-PowerCLIConfiguration -Scope User -InvalidCertificateAction Ignore -ParticipateInCeip $false -Confirm:$false | Out-Null
Connect-VIServer -Server 192.168.2.20 -Credential $cred -WarningAction SilentlyContinue | Out-Null
if (Get-VM -Name grafana01 -ErrorAction SilentlyContinue) { throw "A VM named 'grafana01' already exists." }
$ds = Get-Datastore SSD-2
New-PSDrive -Name gds -PSProvider VimDatastore -Root '\' -Datastore $ds | Out-Null
foreach ($f in @("$b\iso\Rocky-9.8-x86_64-minimal.iso", "$b\grafana01\grafana01-oemdrv.iso")) {
  $leaf = Split-Path $f -Leaf; $have = Get-Item "gds:\iso\$leaf" -ErrorAction SilentlyContinue
  if ($have -and $have.Length -eq (Get-Item $f).Length) { Log "already on datastore: iso/$leaf" }
  else { Log "uploading $leaf"; Copy-DatastoreItem -Item $f -Destination "gds:\iso\$leaf" -Force; Log "uploaded iso/$leaf" }
}
Remove-PSDrive gds
$vmhost = Get-Cluster Prod-Cluster | Get-VMHost | Where-Object ConnectionState -eq 'Connected' | Sort-Object MemoryUsageGB | Select-Object -First 1
$pg = Get-VirtualPortGroup -VMHost $vmhost -Name 'VM Network' -Standard
$vm = New-VM -Name grafana01 -VMHost $vmhost -Datastore $ds -DiskGB 80 -DiskStorageFormat Thin -MemoryGB 4 -NumCpu 2 -GuestId rhel9_64Guest -Portgroup $pg -CD -Location (Get-Folder LAB2.0)
$spec = New-Object VMware.Vim.VirtualMachineConfigSpec
$spec.Firmware = [VMware.Vim.GuestOsDescriptorFirmwareType]::efi
$spec.BootOptions = New-Object VMware.Vim.VirtualMachineBootOptions; $spec.BootOptions.EfiSecureBootEnabled = $true
$vm.ExtensionData.ReconfigVM($spec)
Get-CDDrive -VM $vm | Set-CDDrive -IsoPath "[SSD-2] iso/Rocky-9.8-x86_64-minimal.iso" -StartConnected:$true -Confirm:$false | Out-Null
New-CDDrive -VM $vm -IsoPath "[SSD-2] iso/grafana01-oemdrv.iso" -StartConnected:$true | Out-Null
Start-VM -VM $vm -Confirm:$false | Out-Null
Log "grafana01 created on $($vmhost.Name) and powered on - unattended Rocky install running (powers off when done)"
$deadline = (Get-Date).AddMinutes(45)
do { Start-Sleep 30; $vm = Get-VM -Name grafana01 } while ($vm.PowerState -eq 'PoweredOn' -and (Get-Date) -lt $deadline)
if ($vm.PowerState -eq 'PoweredOn') { throw "Install did not power the VM off within 45 min - check the console." }
Log "install finished (VM powered off) - detaching both CDs and booting"
Get-CDDrive -VM $vm | Set-CDDrive -NoMedia -Confirm:$false | Out-Null
Start-VM -VM $vm -Confirm:$false | Out-Null
$deadline = (Get-Date).AddMinutes(10)
while (-not (Test-NetConnection 192.168.2.13 -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue)) { if ((Get-Date) -gt $deadline) { throw "SSH on 192.168.2.13 did not come up within 10 min." }; Start-Sleep 15 }
Log "GRAFANA01 UP: ssh labadmin@192.168.2.13"
Disconnect-VIServer -Confirm:$false
