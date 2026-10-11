# Microsoft Support Case — Azure Local deployment input-parameter XML parse failure

> Copy-paste ready. Open from Azure Portal → **Help + support → Create a support request**
> → Issue type **Technical** → Service **Azure Local / Azure Stack HCI**.

## Contact & case details
- **Name:** Stephen Palermo
- **Email:** stephen.t.palermo@intel.com
- **Phone:** 602-300-8393
- **Date prepared:** 2026-10-10 (time: ______ local — set when submitting)
- **Subscription ID:** 260f1e88-d954-4946-9d66-876b6722ffc4
- **Preferred contact method:** email / phone

## Title
Azure Local single-node deployment fails at "Validating input parameters" — `Cannot convert "" to System.Xml.XmlDocument` (hex 0x00)

## Severity
B or C — deployment fully blocked, no production impact (greenfield single-node).

## Summary
Single-node Azure Local deployment fails every attempt during the environment-validation / input-parameter stage. The on-node deployment log (`C:\CloudDeployment\Logs\Script.*.log`) ends with:

```
Validating input parameters.
Error: Cannot convert value "" to type "System.Xml.XmlDocument".
Error: '.', hexadecimal value 0x00, is an invalid character. Line 1, position 1.
```

After this line the `DeploymentLauncherService` hangs at 0% (portal shows "In Progress" indefinitely). The Activity Log eventually reports:
`Failing action plan as execution stuck at: InvokeEnvironmentChecker step for 10 hours.`

So the environment checker never actually runs — the deployment tool throws while casting an **empty string to `[xml]`** during input validation, then hangs instead of failing cleanly.

## Environment
- Hardware: **Dell PowerEdge XR8620t**, single node, hostname `GP82K74`. **NOTE: this model is NOT yet Microsoft-certified for Azure Local** (in pre-certification; being tested as a near-equivalent of certified XR-series systems). No published Dell **Solution Builder Extension (SBE) / OEM package** exists for it yet.
- NIC: Broadcom NetXtreme E-Series Dual-port 25Gb (Embedded NIC 1). On the 2608 image the NIC driver is not in-box and must be injected (`pnputil`).
- OS tested: **2609** (26100.33438, CloudDeployment 10.2609.0.6) — fails early; and **2608** (26100.33296, CloudDeployment 10.2608.0.11) — passes validation + domain-join, fails later at SBE.
- Subscription: `260f1e88-d954-4946-9d66-876b6722ffc4`
- Tenant: `aad3d65b-b317-4b0a-b150-8106381dff6c`
- Region: `eastus`; Resource group: `ai-apps-1`
- Active Directory: standalone Windows Server 2022 DC, domain `xeon-edge-ai-az.lab`, deployment account `azlocaldeploy`, OU `OU=AzureLocal,DC=xeon-edge-ai-az,DC=lab`
- Networking: single "group all traffic" intent; reserved IPs 192.168.201.20–25; gateway 192.168.201.1; DNS 192.168.201.10
- Storage: 2 poolable NVMe (`CanPool=True`) + separate OS disk

## What has been verified / ruled out
- All environment-validator prerequisites pass or were remediated:
  - Local admin SID / credential (local `Admin` account created, password matched)
  - External AD connectivity (ports 389/88/445/135 reachable node→DC; DC firewall profile Private)
  - Physical Disk minimum (2 disks `CanPool=True`)
  - Network RDMA check
- Reproduces after a **full clean restart**: deleted `deploymentSettings/default` + cluster + Key Vault + storage account, cleared all `CanNotDelete` locks, rebooted both node and DC.
- Reproduces across **two different network configurations**:
  1. storage VLAN 711 + manual `overrideAdapterProperty=true` (RDMA override)
  2. storage VLAN 1 + `overrideAdapterProperty=false`
  Identical `XmlDocument 0x00` error both times → **not configuration-related**.
- OS fully patched; no Windows Updates available; UBR unchanged at 33438.
- Arc agent healthy (Connected); required `AzureEdge*` extensions provisioned "Succeeded".

## Request
Identify the deployment input parameter being cast to `[xml]` with an empty value during "Validating input parameters", and provide a fix / hotfix, or confirm the build in which this is resolved.

## Root-cause detail (from on-node log analysis)
Analysis of `C:\CloudDeployment\Logs\Script.*.log` shows all parameters assign successfully, then at `Validating input parameters` the tool casts a value that is a **run of spaces + an embedded `0x00`** to `[xml]`, which throws. The invocation line passes `-SqlActivationKey System.Security.SecureString` — an **empty SecureString** for this deployment. Marshaling an empty SecureString back to text yields the whitespace+null value, so the most likely culprit is `BootstrapCloudDeploymentTool.ps1` (package **CloudDeployment 10.2609.0.6**) parsing an empty `SqlActivationKey` as XML. `SqlActivationKey` is not exposed in the portal wizard, so the customer cannot work around it via configuration. `Unattended.json` is well-formed. Secondary suspects (empty single-node witness fields `WitnessType=`/`WitnessPath=`, empty security toggles `VBSProtection=`/`SEDProtectionEnforced=`) are empty strings rather than whitespace, so less likely.

## Version comparison (confirms a 2609 regression)
The identical deployment on **Azure Local 2608** (`CloudDeployment 10.2608.0.11`, OS build 26100.33296) passes the "Validating input parameters" stage with **no `XmlDocument`/`0x00` error** and proceeds into the environment validator. Only **2609** (`CloudDeployment 10.2609.0.6`, OS 26100.33438) fails. This isolates the defect to the **2609 BootstrapCloudDeploymentTool** handling of the empty `SqlActivationKey` SecureString. Request: port the 2608 behavior / fix the empty-SecureString XML cast in 2609.

## Second issue — default (no-SBE) deployment path fails at GetAccessControl on 2608
On **2608**, deployment progresses much further: validation passes, the node **domain-joins** (`PartOfDomain=True`), then it **stops at the Solution Builder Extension (SBE) configuration** step. Per Microsoft's SBE documentation, hardware **without** an SBE is **supported** and uses a **default SBE version 2.1.0.0** (Validated Nodes / pre-2311.2 hardware operate this way) — so an OEM/SBE package is NOT a hard requirement. The log shows the default no-SBE path being taken and then failing:
```
Extension package not found at 'C:\SBE' or 'C:\CloudDeployment\OEMPackage' ... skipping.
No SBE extracted. Updating ECE config to reflect Manufacturer 'Dell Inc.', Model 'PowerEdge XR8620t'...
Create SBE Configuration with version: '2.1.0.1'.
Need to re-create the SBE Configuration nuget 'C:\CloudDeployment\NuGetStore\Microsoft.AzureStack.SBEConfiguration.2.1.0.1.nupkg'.
Prior SBE Configuration nuget installs exist. Removing 'C:\NuGetStore\Microsoft.AzureStack.SBEConfiguration.2.1.0.1' directory.
Error: Exception calling "GetAccessControl" with "0" argument(s): "Attempted to perform an unauthorized operation."
```
The deployment creates the **default SBE Configuration 2.1.0.x** (the supported no-SBE path) and then fails on `GetAccessControl` while re-creating the SBE nuget. Context: the Dell XR8620t is in pre-certification (no published Dell SBE, and the XR-series has no SBE listed — only Dell AX-series), but per the docs an SBE is **not required**; the default path should succeed. A mismatched vendor/model SBE is rejected by the manifest check, so there is no package to "borrow."
**Questions for Microsoft:** (1) The default (no-SBE) SBE-configuration path (default version 2.1.0.0) fails at `GetAccessControl` "unauthorized operation" on a cleanly imaged node — is this a known defect in a supported path? (2) What privilege/permission does the SBE-config step require, and why would `GetAccessControl` fail? (3) Any supported way to complete deployment on this hardware (pre-certification, no SBE)?

## Logs to attach
Collect these before submitting (checklist):
- [ ] **`C:\CloudDeployment\Logs\Script.<latest>.log`** — shows the full parameter-assignment block followed by the failing `XmlDocument` line. (Example captured: `Script.2026-10-09.11-33-39.log`.)
- [ ] **Entire `C:\CloudDeployment\Logs\` folder** (zip it) — full deployment/ECE engine logs for context.
- [ ] **`C:\Deployment\Unattended.json`** — the generated answer file (confirms the config is well-formed). **Redact any secret/password values before sending.**
- [ ] **Portal deployment Activity Log JSON** (`microsoft.azurestackhci/clusters/deploymentSettings/write`, status Failed) — contains the `statusMessage` with the `execution stuck at: InvokeEnvironmentChecker` exception.
- [ ] **`azcmagent show` output** from the node — proves Arc agent Connected + extensions healthy.
- [ ] **`Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"`** (CurrentBuild/UBR) — proves build 26100.33438, fully patched.
- [ ] Optional: **Support log package** via the Configurator app (`Upload the Support log package`) — bundles all node logs for Microsoft.

## Reference
Full troubleshooting history: `Azure-Local.README.md` in this repo.
