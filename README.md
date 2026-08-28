# powerplatform-ai-blocking

Tooling to audit and enforce the deactivation of AI processes across Power Platform
environments at tenant scale, and to produce dated evidence that the state holds.

**Why any of this is necessary, what it does and does not close, and what the
alternatives are** is all in the companion article. This README covers deployment
and testing only.

> 📄 Companion article: *Blocking AI in Power Platform*. Link is in the repo
> description.

---

## Layout

```
config.example.json                  copy to config.json, fill in, never commit
queries/                             read-only FetchXML, safe against production
  01-resolve-object-type-codes.xml
  02-ai-process-inventory.xml
  03-ai-plugin-steps.xml
  README.md                          how to run the queries
scripts/
  Test-Prerequisites.ps1             run this first
  Bootstrap-AppUsers.ps1             one-time, seeds the app as an Application User
  Invoke-AIBlockade.ps1              the entry point
  PPAIBlock.psm1                     the module
```

If you only want to *look*, read `queries/README.md` and stop there. Those three
queries change nothing and need no app registration.

---

## Prerequisites

| | Minimum | Check |
|---|---|---|
| PowerShell | **7.x** | `pwsh -v` |
| Power Platform CLI | current | `pac --version` |
| Role | Power Platform Administrator or Global Administrator | |

**PowerShell 7 is not optional.** The module declares `#requires -Version 7.0` and
uses `ForEach-Object -Parallel`, which does not exist in Windows PowerShell 5.1.
Launch with `pwsh`, not `powershell`.

Install the CLI if you need it:

```
dotnet tool install --global Microsoft.PowerApps.CLI.Tool
```

---

## Setup

### 1. Register an application

In Entra ID, create an app registration. Add a client secret. Note the
**Directory (tenant) ID** and the **Application (client) ID**.

Under **API permissions**, add:

- `Dynamics CRM` → `user_impersonation` (delegated)

Grant admin consent.

### 2. Supply the secret through the environment

The scripts read the secret from an environment variable and never from a file or
a command-line argument. Nothing sensitive lands on disk or in shell history.

```powershell
$env:PPAI_CLIENT_SECRET = Read-Host -AsSecureString |
    ForEach-Object { [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($_)) }
```

Or paste it directly in an interactive session you are about to close.

### 3. Configure

```powershell
Copy-Item config.example.json config.json
```

Edit `config.json`:

| Key | Notes |
|---|---|
| `tenantId` | Directory (tenant) ID |
| `clientId` | Application (client) ID |
| `secretEnvVar` | Name of the env var above. Default `PPAI_CLIENT_SECRET`. |
| `selection.groupName` | Environment group to target |
| `selection.namePattern` | Wildcard on environment display name |
| `selection.environmentIdFile` | Path to a file of environment GUIDs, one per line |
| `throttleLimit` | Environments in flight. Start at 8. |
| `additionalProcessNames` | Extra process names beyond the four AI entities |

Precedence is `environmentIdFile` → `groupName` → `namePattern`.

> ⚠️ **If all three selectors are null the run targets every Dataverse-backed
> environment in the tenant.** That is a legitimate mode. Choose it deliberately.

`config.json` is gitignored. Keep it that way.

### 4. Check the prerequisites

```powershell
pwsh ./scripts/Test-Prerequisites.ps1
```

Resolve everything it reports before going further.

### 5. Seed the Application User

A service principal cannot call the Dataverse Web API in an environment until it
exists there as an Application User with the System Administrator role. This is
one-time per environment and is idempotent.

```powershell
pwsh ./scripts/Bootstrap-AppUsers.ps1
```

It runs sequentially on purpose. Entra replication behind this call does not
reward concurrency.

---

## Running

### Audit, reads only, changes nothing

```powershell
pwsh ./scripts/Invoke-AIBlockade.ps1 -Mode Audit
```

Start here. Always. It shows you the shape of the tenant and the current state of
every AI process, and writes a CSV you can hand to an auditor.

### Enforce, deactivates

```powershell
pwsh ./scripts/Invoke-AIBlockade.ps1 -Mode Enforce
```

Idempotent. A process already deactivated is skipped, not re-patched, so
re-running after a partial failure is safe and cheap.

### Exit codes

| Code | Meaning | In a pipeline |
|---|---|---|
| `0` | Every targeted environment compliant | pass |
| `1` | One or more environments non-compliant | **fail the build** |
| `2` | The run itself failed: auth, config, connectivity | fail and page someone |

`1` and `2` are different failures. Do not collapse them into "non-zero".

### Output

Each run creates `scripts/runs/<yyyyMMdd-HHmmss>/`:

| File | Contents |
|---|---|
| `compliance-evidence.csv` | One row per environment: counts found / draft / active, a `Compliant` flag, the names of anything still active, and duration |
| `errors.csv` | Written only if something failed. Same rows, plus the exception message. |

Plus `scripts/runs/checkpoint.json`, which is *not* per-run. It accumulates the
IDs of environments already enforced successfully, so a run that dies mid-way
resumes from it rather than restarting. Delete it to force a full re-run.

Everything under `runs/` is gitignored. It contains environment names, URLs and
GUIDs, so keep it that way.

---

## Testing it worked

Three levels, cheapest first.

### 1. Re-audit

```powershell
pwsh ./scripts/Invoke-AIBlockade.ps1 -Mode Audit
```

Exit `0`, and every row in the CSV showing `Draft`.

### 2. Query the environment directly

Independent of the scripts, which is the point. You are testing the environment,
not the tool that changed it.

```
pac org select --environment https://yourorg.crm.dynamics.com/
pac env fetch --xmlFile queries/02-ai-process-inventory.xml
```

Every row should read `Draft`. Read `queries/README.md` first: the object type
codes in that file **must** be replaced with your own.

### 3. Try to use the feature

The only test that proves anything to a control owner. In the maker portal, open
**AI Builder → Explore**, pick a prebuilt model, and attempt to use it.

Also confirm you have not broken anything you needed:

- open a model-driven app in the environment and create, edit and delete a record
- import a managed solution and confirm it deploys clean

### Re-test after every solution import

Solution import touches process state. Make the audit a post-deployment gate, not
a one-time exercise. Exit code `1` is designed for exactly this.

---

## Rolling back

There is no `-Mode Revert`, deliberately. Mass-reactivating AI processes is not
an operation that should be one flag away.

To reverse a single environment, PATCH `statecode = 1` / `statuscode = 2` on the
`workflow` records for that environment. Run an audit *before* enforcing and keep
the CSV. The `ProcessesFound` and `ProcessesDraft` columns tell you what was
already deactivated before you touched anything, which is what you need in order
to put it back the way it was rather than the way it shipped.

---

## Troubleshooting

**`Import-Module` fails on `#requires -Version 7.0`**
You are in Windows PowerShell 5.1. Use `pwsh`.

**`Cannot run a document in the middle of a pipeline`**
`$env:PATHEXT` has been clobbered on the machine and no longer contains `.EXE`.
The module normalises this for its own process. If you hit it in your own shell:
`$env:PATHEXT = '.COM;.EXE;.BAT;.CMD;.PS1'`.

**`pac` not found even though it is installed**
Same root cause. The module falls back to known install locations.

**The audit returns zero environments**
The selector matched nothing. It warns rather than reporting success. Check
`groupName` spelling against `pac admin list`, and note that name matching is
case-sensitive.

**`System.Xml.XmlException` from `pac env fetch`, with exit code 0**
The `.xml` file is malformed. The usual cause is a double hyphen inside an XML
comment, which is illegal. Watch for CLI flags pasted into comment headers.
**The exit code is `0` regardless**, so do not trust it here. Check the output.

**429 / 502 / 503 / 504**
Handled. The module retries with backoff and honours `Retry-After`. If it
persists, lower `throttleLimit`.

**A run reports compliant but the feature still works**
Most likely the object type codes are wrong for that environment, so agent
processes were never in scope. Re-run query 01 against that specific environment.

---

## Notes

Deactivating platform processes is not a documented configuration surface, and
platform updates can change what ships and what it is called. Nothing here is
covered by Microsoft support. Run the audit in a non-production environment
first, and treat the audit as an ongoing control rather than a one-time change.

Everything here reflects behaviour observed at a point in time. Verify it against
your own tenant before relying on it.

---

## License

MIT. See [LICENSE](LICENSE).

Personal project. Not affiliated with, endorsed by, or representing any employer.
