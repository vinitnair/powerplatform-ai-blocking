# Queries

Three read-only FetchXML queries. Nothing here changes state — you can run all of
them against production safely.

## Running them

```bash
pac org select --environment https://yourorg.crm.dynamics.com/
pac env fetch --xmlFile queries/01-resolve-object-type-codes.xml
```

To keep the output:

```bash
pac env fetch --xmlFile queries/02-ai-process-inventory.xml > evidence-$(date +%Y%m%d).txt
```

## Order of use

| File | Purpose |
|---|---|
| `01-resolve-object-type-codes.xml` | **Run this first.** Returns the four object type codes for your organization. |
| `02-ai-process-inventory.xml` | The compliance query. Paste your codes from step 01 into it first. |
| `03-ai-plugin-steps.xml` | Optional inventory of AI plug-in registration steps. |

## Why step 01 is not optional

Object type codes at or above 10000 are assigned **per organization**. Both agent
tables (`bot`, `botcomponentcollection`) sit in that range, so the values that work
in one environment will be wrong in another.

Getting this wrong does not throw an error. The query simply returns fewer rows,
every returned row is compliant, and the report is green while agent processes
remain untouched. Resolve the codes per environment, every time.

The two AI Builder tables (`msdyn_aimodel` = 401, `msdyn_aiconfiguration` = 402)
are below 10000 and are stable across organizations.

## Reading the output

`pac env fetch` renders both columns as friendly labels rather than raw integers:

- `primaryentity` → `AI Model`, `AI Configuration`, `Agent`, `Agent component collection`, or `none`
- `statecode` → `Draft` (deactivated) or `Activated`
- `type` → `Definition`

A fully blocked environment returns every row as `Draft`.

## Three traps

**`primaryentity` is an `Int32`.** A filter such as `primaryentity like 'msdyn_ai%'`
throws `System.FormatException: Expected type of attribute value: System.Int32`.
That is the whole reason step 01 exists.

**`type = 1` restricts results to Definition records.** Each process also has
Activation children. Those children are *deleted during solution import* — a count
of 14 dropping to 6 has been observed across a single import with the block
completely intact. **Assert on `statecode`, never on how many rows come back.**

**A double hyphen is illegal inside an XML comment.** Pasting a CLI example
containing `--xmlFile` into the comment header of a query file makes the file
invalid XML. `pac` then fails with a bare `System.Xml.XmlException`, a telemetry
session ID, and — the part that will cost you time — **exit code 0**. That is why
the usage examples live in this file rather than inside the `.xml` files.

## Adapting these

`IsPaiEnabled` is included by name because its `primaryentity` is `none`, so a
Primary-Entity filter alone misses it. If you find other AI processes in your own
environment that sit outside the four entities, add them to the same `<condition
attribute="name" operator="in">` branch rather than widening the entity list.
