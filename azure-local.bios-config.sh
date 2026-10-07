#!/usr/bin/env bash
#
# azure-local.bios-config.sh
# Configures Dell iDRAC BIOS settings for an Azure Local (HCI) node,
# applies the changes via a staged BIOS config job, and reboots gracefully.
#
set -euo pipefail

IDRAC_IP="192.168.201.32"
IDRAC_USER="root"
IDRAC_PASS="calvin"

RACADM="racadm -r ${IDRAC_IP} -u ${IDRAC_USER} -p ${IDRAC_PASS}"

echo "=== Applying BIOS configuration to ${IDRAC_IP} ==="

# --- 1. Global Network & Virtualization Acceleration Master Key ---
${RACADM} set BIOS.IntegratedDevices.SriovGlobalEnable Enabled

# --- 2. Boot & Mandatory Secure Boot Settings ---
${RACADM} set BIOS.BiosBootSettings.BootMode Uefi
${RACADM} set BIOS.SysSecurity.SecureBoot Enabled
${RACADM} set BIOS.SysSecurity.SecureBootPolicy Standard
${RACADM} set BIOS.SysSecurity.SecureBootMode DeployedMode

# --- 3. Processor & Hyper-V Requirements ---
${RACADM} set BIOS.ProcSettings.VirtualizationTech Enabled
${RACADM} set BIOS.ProcSettings.X2ApicMode Enabled

# --- 4. Hardware Attestation & Security (TPM 2.0) ---
${RACADM} set BIOS.SysSecurity.TpmSecurity On
${RACADM} set BIOS.SysSecurity.Tpm2Hierarchy Enabled

# --- 5. Performance & Resiliency Profiles ---
${RACADM} set BIOS.SysProfileSettings.SysProfile Performance
${RACADM} set BIOS.SysSecurity.AcPwrRcvry Last

echo "=== Verifying applied (pending) settings ==="

# Verify Global Networking & Boot
${RACADM} get BIOS.IntegratedDevices.SriovGlobalEnable
${RACADM} get BIOS.BiosBootSettings.BootMode
${RACADM} get BIOS.SysSecurity.SecureBoot
${RACADM} get BIOS.SysSecurity.SecureBootPolicy
${RACADM} get BIOS.SysSecurity.SecureBootMode

# Verify Compute & Crypto Security
${RACADM} get BIOS.ProcSettings.VirtualizationTech
${RACADM} get BIOS.ProcSettings.X2ApicMode
${RACADM} get BIOS.SysSecurity.TpmSecurity
${RACADM} get BIOS.SysSecurity.Tpm2Hierarchy

# Verify Power & Performance
${RACADM} get BIOS.SysProfileSettings.SysProfile
${RACADM} get BIOS.SysSecurity.AcPwrRcvry

echo "=== Creating BIOS config job and rebooting gracefully ==="

# Create the deployment master job and reboot the server gracefully
${RACADM} jobqueue create BIOS.Setup.1-1 -r Graceful

# Monitor the status of the job execution as the system passes through POST
${RACADM} jobqueue view

echo "=== Done ==="
