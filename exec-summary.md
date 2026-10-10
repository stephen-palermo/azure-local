# Executive Summary — Azure Local Edge AI Node

**Date:** 2026-10-10 · **Prepared by:** Stephen Palermo (stephen.t.palermo@intel.com) · **Day 10 of effort**

---

## Status (Day 10)

**Goal:** Stand up a single Dell PowerEdge XR8620t as an Azure Local node to run our Kubernetes AI application, managed from Azure.

**Done:** Node registered to Azure Arc; built the required Active Directory / DNS; passed every hardware, network, storage, and identity validation (added an NVMe drive to meet storage minimums). **~90% complete and fully documented.**

**Blocker:** The final deployment hits a **bug in Microsoft's Azure Local 2609 release**. We traced it to the exact component — the deployment tool crashes while parsing one of its *own* internal parameters (an empty `SqlActivationKey` cast to XML). Confirmed **not our configuration**: it reproduces on a clean rebuild across multiple settings, and our config files are well-formed.

**Path forward — reverting to the prior release (2608), and here's why it's targeted, not trial-and-error:** In Azure Local, the deployment tooling ships *inside* the OS image, so each version carries its own copy of the failing component. Since we've pinpointed the defect to the **2609** build's tool, installing the immediately-previous **2608** build runs a *different version of that exact code path* — the most direct way to bypass a version-specific regression. We're rebuilding the node on 2608 now.

**In parallel:** Filing a **Microsoft support case** with the precise root cause (attached) so Microsoft can confirm/fix it — this protects us if 2608 also carries the bug (then we drop to 2607) and gets it corrected upstream.

**Expected outcome:** Deployment completes on 2608 (or 2607), then we proceed to the Kubernetes / AI app.

---

## Timeline (Sep 30 – Oct 10, 2026 — 10 days)

| Date | Milestone |
| --- | --- |
| Sep 30 – Oct 1 | Arc registration — resolved device-login failures with a service principal; node **Connected** |
| Oct 3–4 | Determined Azure Local requires **Active Directory** (node was workgroup) |
| Oct 5 | Built a **domain controller** (Windows Server 2022 VM on the NUC) + AD prep |
| Oct 6 | Cleared deployment validation errors (local-admin SID, AD firewall) |
| Oct 7 | Hit **storage hardware** minimum (needed 2 poolable disks); authored the runbook |
| Oct 8 | Added a **PCIe NVMe drive**, cleaned disks, resolved the RDMA check |
| Oct 9 | Cleared duplicate instances/locks; deployment **hung** → traced to a **2609 tool bug** (`[xml]` parse of empty `SqlActivationKey`) |
| Oct 10 | Prepared **Microsoft support case** + print-ready HTML; started **2608 downgrade** reimage |

**Net:** The infrastructure, identity, networking, storage, and Arc layers are complete and documented. The only remaining obstacle is a **Microsoft product bug**, addressed by the 2608 rebuild and/or the support case.

---

*References: `support-case.md` / `support-case.html` (Microsoft case), `Azure-Local.README.md` (full technical runbook).*
