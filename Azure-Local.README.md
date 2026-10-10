# Azure Local — End-to-End Runbook (Edge AI on Azure Local)

> **Purpose:** A repeatable, detailed procedure for taking a bare Azure Local node all the way
> to running a Kubernetes-based AI application managed by the Azure Local framework.
> This document is a living runbook — **keep appending** as more nodes/apps are added.
>
> **Legend for "where to run":**
> - 🟦 **Node** = the Azure Local machine (Azure Stack HCI OS), e.g. `GP82K74`
> - 🟩 **DC** = the Domain Controller VM (Windows Server in VirtualBox on the NUC)
> - 🟨 **Cloud Shell** = Azure Portal Cloud Shell (PowerShell), signed in as the admin account
> - 🟧 **Portal** = Azure Portal GUI (https://portal.azure.com)
> - ⬜ **NUC** = the Windows 11 Home mini-PC hosting the DC VM / used for remote access

---

## 0. Environment Inventory (fill in per deployment)

| Item | Value |
|---|---|
| Azure Subscription | `260f1e88-d954-4946-9d66-876b6722ffc4` ("Azure Local Xeon Edge AI" / "Xeon Edge AI") |
| Entra Tenant | `aad3d65b-b317-4b0a-b150-8106381dff6c` ("Default Directory") |
| Tenant primary domain | `stephentpalermogmail.onmicrosoft.com` |
| Admin account (use this, NOT a personal Gmail) | `stephen@stephentpalermogmail.onmicrosoft.com` (Owner + Global Admin) |
| Break-glass / original owner | `stephen.t.palermo@gmail.com` (personal MSA — keep for recovery, don't use day-to-day) |
| Azure region (Azure Local supported) | `eastus` |
| Resource group | `ai-apps-1` |
| Node hostname | `GP82K74` (Dell PowerEdge XR8620t) |
| Node LAN IP | `192.168.201.12/24`, gateway `192.168.201.1` |
| DC hostname / FQDN | `DC1` / `DC1.xeon-edge-ai-az.lab` |
| AD domain / NetBIOS | `xeon-edge-ai-az.lab` / `XEONEDGEAI` |
| DC LAN IP | `192.168.201.10/24` (VirtualBox bridged) |
| DC DNS forwarders | `1.1.1.1`, `8.8.8.8` |
| Reserved infra IP block (6) | `192.168.201.20` – `192.168.201.25` |
| AD deployment account | `azlocaldeploy` (in `OU=AzureLocal,DC=xeon-edge-ai-az,DC=lab`) |
| Node local admin (for wizard) | `Admin` (local account created on node — see Phase 4) |

> ⚠️ **Secrets:** Never store client secrets / passwords in this file. Use a password manager.
> Supported Azure Local regions: `eastus, eastus2euap, westeurope, australiaeast, southeastasia,
> centralindia, canadacentral, japaneast, southcentralus, germanywestcentral`. **`westus2` is NOT supported.**

---

## Phase 1 — Register the Node with Azure Arc

**Goal:** Make the node appear in Azure as an Arc-enabled machine so Azure Local deployment can target it.

### 1.1 Key lessons (read first)
- ❌ **A personal Microsoft account (Gmail/outlook) CANNOT do Arc/Azure Local onboarding.** Create a
  native **member** user in the tenant (`...onmicrosoft.com`) and grant it **Owner** (+ Global Admin).
- ✅ **Register required resource providers BEFORE onboarding** (the onboarding app must exist in the tenant).
- ❌ **Device-code login (`-UseDeviceAuthentication`) failed with `AADSTS900561`** (“endpoint only accepts
  POST, received GET”) on both corporate (Intel DMZ) and home networks. Root cause not fully pinned
  (likely URL/link-scanner interference).
- ✅ **Workaround that works: a SERVICE PRINCIPAL (non-interactive) login.** No browser, no device code.

### 1.2 One-time prep (🟨 Cloud Shell as the member admin account)
Register resource providers:
```powershell
az account set --subscription "260f1e88-d954-4946-9d66-876b6722ffc4"
$rps = @(
  "Microsoft.HybridCompute","Microsoft.GuestConfiguration","Microsoft.HybridConnectivity",
  "Microsoft.AzureStackHCI","Microsoft.Kubernetes","Microsoft.KubernetesConfiguration",
  "Microsoft.ExtendedLocation","Microsoft.ResourceConnector","Microsoft.HybridContainerService",
  "Microsoft.Attestation","Microsoft.Storage","Microsoft.Insights","Microsoft.KeyVault"
)
foreach ($rp in $rps) { az provider register --namespace $rp }
# verify all show "Registered":
foreach ($rp in $rps) { az provider show --namespace $rp --query "{p:namespace,s:registrationState}" -o tsv }
```

### 1.3 Create the service principal (🟨 Cloud Shell)
```powershell
$sub = "/subscriptions/260f1e88-d954-4946-9d66-876b6722ffc4"
$sp = az ad sp create-for-rbac --name "arc-node-onboarding" --role "Contributor" --scopes $sub | ConvertFrom-Json
az role assignment create --assignee $sp.appId --role "Azure Connected Machine Onboarding" --scope $sub
az role assignment create --assignee $sp.appId --role "Azure Connected Machine Resource Administrator" --scope $sub
# RECORD these two (secret shown once):
Write-Host "APP ID : $($sp.appId)"
Write-Host "SECRET : $($sp.password)"
```

### 1.4 Register the node (🟦 Node, elevated PowerShell)
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
foreach ($m in 'Az.Accounts','Az.Resources','Az.ConnectedMachine','AzsHci.ARCinstaller') {
    if (-not (Get-Module -ListAvailable -Name $m)) { Install-Module $m -Force -AllowClobber -Repository PSGallery }
}

$appId  = '<APP ID from 1.3>'
$secret = Read-Host -AsSecureString 'Paste the service principal SECRET'
$cred   = [pscredential]::new($appId, $secret)

Connect-AzAccount -ServicePrincipal -Credential $cred `
    -TenantId 'aad3d65b-b317-4b0a-b150-8106381dff6c' `
    -SubscriptionId '260f1e88-d954-4946-9d66-876b6722ffc4'

# token (handles both plaintext and SecureString Az versions):
$tokenObj = Get-AzAccessToken
if ($tokenObj.Token -is [System.Security.SecureString]) {
    $armToken = [System.Net.NetworkCredential]::new('', $tokenObj.Token).Password
} else { $armToken = $tokenObj.Token }
$acct = (Get-AzContext).Account.Id

Invoke-AzStackHciArcInitialization `
    -SubscriptionID '260f1e88-d954-4946-9d66-876b6722ffc4' `
    -ResourceGroup  'ai-apps-1' `
    -TenantID       'aad3d65b-b317-4b0a-b150-8106381dff6c' `
    -Region         'eastus' `
    -Cloud          'AzureCloud' `
    -ArmAccessToken $armToken `
    -AccountID      $acct
```
> ⚠️ **Region must be `eastus`** (not `westus2`) — otherwise: *"Region 'westus2' is not supported."*

### 1.5 Verify (🟦 Node)
```powershell
& "$env:ProgramFiles\AzureConnectedMachineAgent\azcmagent.exe" show
```
Expect **Agent Status : Connected**, correct RG/Subscription, Location `eastus`.
🟧 Portal: **Azure Arc → Machines** → node shows **Connected**.

### 1.6 Cleanup (🟨 Cloud Shell, after the LAST node is registered)
```powershell
az ad sp delete --id <APP ID>     # SP only needed during onboarding
```

### 1.7 Companion script
`Register-ArcNode.ps1` in this repo automates 1.2–1.4 and supports both device-code and
service-principal (`-ApplicationId` / `-ClientSecret`) sign-in. The manual Phase 1.4 block above is the proven path.

---

## Phase 2 — Stand up Active Directory (Domain Controller)

**Goal:** Azure Local deployment **requires** AD (domain + DNS). Build a DC on the NUC.

### 2.1 Decisions made
- NUC is **Windows 11 Home** (no Hyper-V) and is kept as-is (also used for remote access).
- DC runs as a **Windows Server 2022 (eval) VM in VirtualBox** with a **Bridged** network adapter.
- The node is **NOT** manually domain-joined — the Azure Local deployment joins it automatically.

### 2.2 VirtualBox VM
- Windows Server 2022 **evaluation ISO** → install **Standard (Desktop Experience)**, "I don't have a product key".
- ⚠️ **Skip the VirtualBox "Unattended Installation"** (it causes *"Windows cannot find the Microsoft Software License Terms"* and may install Core). Install manually.
- VM: 4 GB RAM, 2 vCPU, 80 GB disk.
- **Network → Adapter 1 → Bridged Adapter** on the NUC's wired NIC; Advanced → Promiscuous Mode = **Allow All**. (NAT will NOT work — node must reach the DC.)
- Clipboard: **Devices → Insert Guest Additions CD image** → run `VBoxWindowsAdditions.exe` → **reboot** → **Devices → Shared Clipboard → Bidirectional**. (If it won't cooperate, use the Server GUI wizards instead.)

### 2.3 Configure + promote (🟩 DC VM)
Static IP (GUI `ncpa.cpl` or PowerShell):
```powershell
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 192.168.201.10 -PrefixLength 24 -DefaultGateway 192.168.201.1
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 127.0.0.1
Rename-Computer -NewName "DC1" -Restart
```
Promote to DC (PowerShell) — or use Server Manager → Add Roles → AD DS → promote:
```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-ADDSForest -DomainName "xeon-edge-ai-az.lab" -DomainNetbiosName "XEONEDGEAI" -InstallDns -Force
```
DNS forwarders (so the DC resolves internet/Azure names) — DNS Manager → DC1 → Properties → Forwarders, or:
```powershell
Add-DnsServerForwarder -IPAddress 1.1.1.1, 8.8.8.8
```
> "Unable to resolve" next to a forwarder is **cosmetic**; what matters is `Resolve-DnsName login.microsoftonline.com` returns IPs.

### 2.4 Point the node's DNS at the DC (🟦 Node)
```powershell
Get-NetAdapter   # find the adapter alias (e.g. "Embedded NIC 1")
Set-DnsClientServerAddress -InterfaceAlias "<node-adapter>" -ServerAddresses 192.168.201.10
Resolve-DnsName xeon-edge-ai-az.lab   # must return 192.168.201.10
```

### 2.5 Verify DC health (🟩 DC)
```powershell
Get-ADDomain | Format-List DNSRoot, NetBIOSName
Get-Service ADWS, DNS, KDC, Netlogon, NTDS | Format-Table Name, Status   # all Running
```
> The "Microsoft Edge Update Service stopped" warning in Server Manager is harmless — ignore it.

---

## Phase 3 — AD Pre-Creation (OU + Deployment Account)

**Goal:** Create the dedicated OU + deployment user the deployment wizard requires. (No GUI equivalent — PowerShell only.)

### 3.1 Run on the DC (🟩 DC, elevated)
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider -Name NuGet -Force
Install-Module AsHciADArtifactsPreCreationTool -Repository PSGallery -Force

$deployUser = 'azlocaldeploy'
$deployPwd  = Read-Host -AsSecureString 'Set a password for the deployment account'
$cred = [pscredential]::new($deployUser, $deployPwd)
New-HciAdObjectsPreCreation -AzureStackLCMUserCredential $cred -AsHciOUName "OU=AzureLocal,DC=xeon-edge-ai-az,DC=lab"
```
Harden the account:
```powershell
Set-ADUser azlocaldeploy -ChangePasswordAtLogon $false -PasswordNeverExpires $true -Enabled $true
```
Verify:
```powershell
Get-ADUser azlocaldeploy | Format-List Name, Enabled, DistinguishedName   # DN ends in OU=AzureLocal,...
```

### 3.2 Wizard "Active Directory Details" values
| Field | Value |
|---|---|
| Domain (FQDN) | `xeon-edge-ai-az.lab` |
| OU path | `OU=AzureLocal,DC=xeon-edge-ai-az,DC=lab` |
| Deployment account | `azlocaldeploy` (or `XEONEDGEAI\azlocaldeploy`) + password |

---

## Phase 4 — Deploy the Azure Local Instance (🟧 Portal)

**Goal:** Deploy the single-node Azure Local instance (prereq for AKS).

### 4.1 Pre-deploy Azure roles (🟨 Cloud Shell)
Owner does NOT include Key Vault data-plane roles the deployment needs:
```powershell
$sub  = "/subscriptions/260f1e88-d954-4946-9d66-876b6722ffc4"
$user = "stephen@stephentpalermogmail.onmicrosoft.com"
foreach ($r in @("Azure Stack HCI Administrator","Key Vault Data Access Administrator",
                 "Key Vault Secrets Officer","Key Vault Contributor","Storage Account Contributor")) {
    az role assignment create --assignee $user --role $r --scope $sub
}
```

### 4.2 Wizard values
| Page | Field | Value |
|---|---|---|
| Basics | Subscription / RG / Region | `260f1e88-…` / `ai-apps-1` / `eastus` |
| Basics | Instance name | `xeonedgelocal` (≤15 alnum) |
| Basics | Server(s) | `GP82K74` |
| Networking | Management adapter | `Embedded NIC 1` (single-NIC → one intent for mgmt+compute+storage) |
| Networking | Reserved IPs | start `192.168.201.20`, end `192.168.201.25` |
| Networking | Mask / Gateway / DNS | `255.255.255.0` / `192.168.201.1` / `192.168.201.10` |
| Active Directory | Domain / OU / account | `xeon-edge-ai-az.lab` / `OU=AzureLocal,DC=xeon-edge-ai-az,DC=lab` / `azlocaldeploy` |
| Local admin (of node) | username / password | `Admin` / (local account — see 4.3) |

### 4.3 Local admin account on the node (🟦 Node)
The wizard's local-admin username was set to **`Admin`**, which did not exist → create it to match:
```powershell
$pw = Read-Host -AsSecureString 'Password (MUST match the wizard Local admin password)'
New-LocalUser -Name 'Admin' -Password $pw -FullName 'Admin' -Description 'Azure Local deployment admin' -PasswordNeverExpires
Add-LocalGroupMember -Group 'Administrators' -Member 'Admin'
# prove it resolves + logs on:
([System.Security.Principal.NTAccount]'GP82K74\Admin').Translate([System.Security.Principal.SecurityIdentifier])
```
> If you later change the password, keep node account and wizard field **identical** (reset with `net user Admin *`).

### 4.4 Run Validation → Deploy
Validation is a long checklist; fix failures, then **Deploy** (1–2+ hrs, node reboots, auto domain-joins).

---

## Phase 5 — AKS on Azure Local + AI App (PENDING)

**Goal:** Enable AKS (Arc) on the deployed instance, create a cluster, deploy the AI Helm chart,
and iterate on `values.yaml` to demo Azure Local managing the app.

- [ ] Enable **AKS on Azure Local** (AKS Arc) on the instance
- [ ] Create logical network + AKS cluster (`az aksarc create`)
- [ ] Get kubeconfig (`az connectedk8s proxy` / `az aksarc get-credentials`)
- [ ] `helm install` the AI app; iterate `values.yaml` and redeploy
- [ ] (TODO: capture exact commands here once performed)

---

## Troubleshooting Log (symptom → cause → fix)

| Symptom | Cause | Fix |
|---|---|---|
| Device login: **"You don't have access to this"** | Signed in with personal **Gmail** (MSA) | Create native `...onmicrosoft.com` **member** user; grant Owner + Global Admin |
| Still "no access" with member user | Resource providers not registered (Arc app absent) | Register all 13 RPs (Phase 1.2) |
| **AADSTS900561** "endpoint only accepts POST, received GET" | Device-code flow broken (link-scanner/network); fails on corp **and** home nets | Use **service principal** login (Phase 1.4) — no browser |
| **"Region 'westus2' is not supported"** | Azure Local limited regions | Use `eastus` |
| Validation: **"Failed to resolve SID for GP82K74\Admin"** | Local-admin username in wizard doesn't exist on node | Create matching local account (Phase 4.3) |
| Validation: **"CreateProcessWithLogonW … Win32 Error 1326"** | Local-admin password mismatch (bad logon) | Reset node `Admin` pwd = wizard pwd; verify with `Start-Process -Credential` |
| Validation: **External AD "timeout limit exceeded"** | DC firewall profile **Public** blocked LDAP/Kerberos (ports 389/88/445/135) | 🟩 `Set-NetConnectionProfile -InterfaceAlias Ethernet -NetworkCategory Private`; verify `Test-NetConnection .10 -Port 389` = True. **Recheck after DC reboots** (can flip back to Public) |
| Validation: **"PhysicalDisk … Expected at least '2'"** | Only 1 poolable disk (OS consumed Disk 0; only Disk 1 `CanPool=True`) | Add disk(s): **PCIe M.2 NVMe adapter** (chosen), or move OS to a boot device to free both NVMe. Repartitioning does NOT work — S2D needs whole disks |
| New disk still `CanPool=False / Insufficient Capacity` after adding; `Clear-Disk` says **"disk has not been initialized"** (disk is RAW) | Leftover S2D pool metadata from prior failed deploy attempts on the disk | 🟦 Remove leftover `Get-VirtualDisk`/`Get-StoragePool -IsPrimordial $false`; `Reset-PhysicalDisk -UniqueId <id>`; `Update-StorageProviderCache -DiscoveryLevel Full`; last resort `diskpart` → `select disk N` → `clean` (confirm N is NOT the OS disk) |
| Deploy: **`AzureEdgeDeviceManagement` extension provisioning Failed** — DeviceManagementService won't start; event log `Microsoft-Edge-DeviceManagementExtension` missing | Partial/stale extension install from earlier attempts | Reboot node + Retry; if persists `az connectedmachine extension delete … --name AzureEdgeDeviceManagement` then Retry; if "log does not exist" persists, pre-create it: `New-EventLog -LogName "Microsoft-Edge-DeviceManagementExtension" -Source "DeviceManagementService"` |
| `Get-Disk`/`Clear-Disk` **"not recognized"** | Ran in **Cloud Shell (Linux)** by mistake (`PS /home/...`) | Run disk cmdlets **on the node** (Windows); `hostname` must return `GP82K74` |
| Validation: **Network RDMA "OperationalState=False"** on `Embedded NIC 1` (Broadcom NetXtreme E-Series 25Gb) | NIC driver advertises RDMA but platform can't run it; not needed on single node | On the intent set **OverrideAdapterProperty=True** + **NetworkDirect=Disabled** (Networking page → intent → Customize/Advanced). Do NOT bother enabling RoCE in BIOS for single-node |
| **Duplicate Azure Local instances**, both "Failed Validation"; delete blocked by lock | Multiple deploy attempts each created a cluster resource + auto `CanNotDelete` locks | 🟨 Remove locks: `az lock list -g ai-apps-1 --query "[].id" -o tsv \| %{ az lock delete --ids $_ }`; delete clusters `az resource delete -g ai-apps-1 --name <n> --resource-type Microsoft.AzureStackHCI/clusters`; delete leftover Key Vault (`az keyvault delete` + `purge`) and storage account. KEEP the Arc machine `GP82K74` + its AzureEdge* extensions |
| Deploy stuck: Activity Log shows **"execution stuck at: InvokeEnvironmentChecker step for 10 hours"**, PercentComplete=0 | On-node deployment engine (LCM/ECE) wedged from many prior attempts; env checker never launches (no `EnvironmentChecker` process, `C:\CloudDeployment\Logs` stale). NOT a failed check | Reboot node; `Stop-Process DeploymentLauncherService -Force`; `Restart-Service LcmController -Force`. If still 0%, the fix that worked = **full clean restart**: delete `deploymentSettings/default` (clear locks first), then delete cluster + leftover KV/storage, reboot BOTH node and DC (set DC profile Private after), start ONE fresh wizard. (Admin profile already existed — not the cause.) |
| Deploy hangs at "Validating input parameters"; newest `C:\CloudDeployment\Logs\Script.*.log` ends with **"Cannot convert value \"\" to type System.Xml.XmlDocument ... hexadecimal value 0x00 ... Line 1, position 1"** | A deployment input param is an **empty string** being cast to `[xml]`. Traced to custom **network-intent** fields that came out empty: `overrideVirtualSwitchConfiguration:""`, `loadBalancingAlgorithm:""` (from the manual RDMA `overrideAdapterProperty` path) and/or `storageNetworks` VLAN 711. Launcher throws + hangs at 0% (portal stays "In Progress"). Consistent across every run | Recreate deploymentSettings with a **simpler network config**: single-node needs NO storage VLAN (remove `711` storage network); use the simplest "group all traffic" intent and avoid the manual override that produced empty fields. Also check for a **newer Azure Local build** (was 10.2609) that fixes the empty-XML parse. If it persists → Microsoft support with this exact log line. |

---

## Open Items / Next Actions
- [x] Install **PCIe M.2 NVMe adapter** + drive in `GP82K74` to reach ≥2 poolable disks. (Final disk: Dell **PE8010** at DeviceId 2.)
- [x] Clean the new disk — needed `Reset-PhysicalDisk` + storage-cache refresh to clear leftover S2D metadata; now `CanPool=True`. Two poolable disks: PE9010 (DeviceId 1) + PE8010 (DeviceId 2).
- [x] Network RDMA validation — disable RDMA on the intent (OverrideAdapterProperty=True, NetworkDirect=Disabled). Single-node needs no RDMA.
- [x] Cleaned up duplicate failed instances (`az-app-node1`, `xeonedgelocal`) + their locks, leftover Key Vault + storage account. RG now has only `GP82K74` + AzureEdge* extensions.
- [x] Confirmed deployment-tool bug (empty `[xml]` cast) persists across clean restart, two network configs, and fully-patched OS — NOT environment/config.
- [ ] **(Blocked)** Deployment blocked by `XmlDocument 0x00` bug on build 26100.33438 / solution 2609. Next: (a) Microsoft support case — see `support-case.md`; (b) reimage with latest Azure Local ISO if a newer version exists.
- [ ] **(Plan)** Downgrade experiment — reimage with **2608** (OS 26100.33296) first, fall back to **2607** (26100.33158) if same error. Deployment tooling ships inside the OS image (since 2503), so an older ISO = older tool that may lack the bug. NOTE: 2607+ enforces **14-char** local password minimum (Admin + azlocaldeploy). Keep support case open in parallel.
- [ ] Complete Azure Local instance deployment (pending bug fix / newer build).
- [ ] Phase 5: AKS Arc + AI Helm app.
- [ ] Delete onboarding service principal after the last node is registered.

---

## Change Log
- 2026-10-07 — Initial runbook created from end-to-end session (Phases 1–4 complete through hardware blocker; Phase 5 pending).
- 2026-10-08 — Added 3rd NVMe (Dell PE8010) via PCIe adapter; cleared leftover S2D metadata (`Reset-PhysicalDisk`) to make it poolable; documented extension + disk-clean + Cloud-Shell-vs-node fixes. Ready to re-validate.
- 2026-10-09 — Hit network RDMA check (disable on intent). Cleaned up duplicate failed instances + locks + leftover KV/storage; RG reduced to node + extensions. Ready for one clean deployment with all fixes applied.
- 2026-10-09 (later) — Deployment hung at InvokeEnvironmentChecker (0% for 10h). Did FULL clean restart: deleted deploymentSettings/default + cluster + KV + storage (clearing regenerated locks each time), rebooted node + DC (DC profile → Private). RG back to just GP82K74 + AzureEdge* extensions. Next: reboot-both pre-flight → one fresh wizard deployment.
- 2026-10-09 (late) — Clean restart got validation to START (fresh logs), but it hangs at "Validating input parameters" with `[xml]""` 0x00 parse error. Root cause = empty custom network-intent fields (RDMA override / storage VLAN 711). Plan: recreate with simpler network config (no storage VLAN) and/or newer Azure Local build; escalate to MS support if persists.
- 2026-10-09 (final) — Retried with simplified network (storage VLAN=1, overrideAdapterProperty=false): SAME `XmlDocument 0x00` error → CONFIRMED it is NOT our config, it's a **deployment-tool bug in build 26100.33438 (Azure Stack HCI 24H2 / solution 10.2609)**. Decision: update build (Route 1 cumulative updates via sconfig/PSWindowsUpdate, or Route 2 reimage with latest Azure Local ISO) then redeploy. Escalate to MS support with the exact log line if newer build still fails.
- 2026-10-09 (close) — Route 1 exhausted: `Get-WindowsUpdate` found NO updates, OS already current (26100.33438). Created `support-case.md` (copy-paste MS support summary). Path forward: open MS support case + reimage with latest ISO if a newer version than 2609 is available (check https://aka.ms/AzureStackHCIDownload). Deployment is BLOCKED pending one of those.
- 2026-10-09 (version analysis) — Pulled Azure Local release notes. No release explicitly documents this XML bug fix. Version map: 2609=26100.33438, 2608=26100.33296, 2607=26100.33158. Since deployment tooling ships inside the OS image (2503+), plan = downgrade experiment: reimage **2608 first** (smallest step back; clears a 2609 regression), fall back to **2607**. Caveat: 2607+ security baseline requires **14-char** local passwords. Keep support case open in parallel.
- 2026-10-10 (ROOT CAUSE) — Analyzed on-node Script.*.log + Unattended.json. The `[xml]` cast fails on a value that is **whitespace + 0x00** (not empty string). Invocation passes `-SqlActivationKey System.Security.SecureString` = an **empty SecureString**; marshaling it yields whitespace+null, and `BootstrapCloudDeploymentTool.ps1` (CloudDeployment **10.2609.0.6**) parses it as XML → crash + hang. `SqlActivationKey` is NOT exposed in the wizard, so NOT fixable via config — confirms a 2609 product bug. Unattended.json is well-formed. Added detail to support-case.md. Fix path = 2608 downgrade (different tooling) + support case.

<!-- Append new phases, nodes, and apps below. Keep the "where to run" legend icons consistent. -->
