# Microsoft Support Case — Azure Local deployment input-parameter XML parse failure

> Copy-paste ready. Open from Azure Portal → **Help + support → Create a support request**
> → Issue type **Technical** → Service **Azure Local / Azure Stack HCI**.

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
- Hardware: **Dell PowerEdge XR8620t**, single node, hostname `GP82K74`
- NIC: Broadcom NetXtreme E-Series Dual-port 25Gb (Embedded NIC 1)
- OS: **Microsoft Azure Stack HCI, 24H2, build 26100.33438** (fully patched — `Get-WindowsUpdate` returns nothing)
- Solution/package version: **10.2609**
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

## Logs to attach
- `C:\CloudDeployment\Logs\Script.<latest>.log` — shows the full parameter-assignment block followed by the failing `XmlDocument` line.
- Portal deployment **Activity Log** JSON entry (`microsoft.azurestackhci/clusters/deploymentSettings/write`, status Failed) — contains the `statusMessage` with the stuck-checker exception.

## Reference
Full troubleshooting history: `Azure-Local.README.md` in this repo.
