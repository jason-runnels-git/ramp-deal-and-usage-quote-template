# CLAUDE.md — RLM DocGen Ramp+Usage

## Project Purpose

Shareable SFDX project (API v66.0) providing document generation capabilities for Salesforce Revenue Cloud (RLM) quotes. Handles two scenarios:

- **Ramp quotes** — quotes with `QuoteLineGroup` segments, each with different line items and dates
- **Usage-based products** — anchor products with `ProductUsageGrant` records driving included usage and overage rates

Source: extracted and de-branded from the Klaviyo-262 project at `C:\Users\jrunnels\Documents\CURSOR\KLAVIYO\klaviyo-262`.

---

## Critical Architecture: IP vs. Apex TokenData

> **The Integration Procedure (IP) wired to the Document Template in Setup does NOT determine which fields render.**

Here is what actually happens when `rlmRampDocGen` (Quick Action) is clicked:

1. LWC calls `RlmRampDocGenController.generateProposal(quoteId)`
2. Controller delegates to `RlmRampTokenAssembler.assembleTokenData(quoteId)`
3. Assembler builds a `tokenData` `Map<String, Object>` in Apex — **this is the only source of truth for field data**
4. Assembler creates a `DocumentGenerationProcess` (DGP) record with `TokenData = JSON.serialize(tokenData)`
5. Salesforce's DocGen engine reads `DGP.TokenData` and replaces merge fields in the `.docx` template

The IP is mapped to the template for the standard "Generate Document" button — that flow is separate. The custom Apex flow bypasses the IP entirely. Field data comes from `TokenData` on the DGP record.

### Extensibility Rule

To add a new field to the generated document:
1. Query the data in `RlmRampTokenAssembler.assembleTokenData()` (add to existing SOQL or add a new query)
2. Add the key to the `tokenData` map (header-level) or to the appropriate nested list (`linesList`, `usageLines`, or `rampSegments`)
3. Add the matching merge field to the `.docx` Document Template
4. No IP changes required

To remove a field: delete the key from `tokenData` (the merge field in the template will render blank, not error).

---

## tokenData Schema

These are the merge field names as they appear in the Document Template:

### Header Fields
| Key | Source |
|-----|--------|
| `QuoteName` | `Quote.Name` |
| `QuoteNumber` | `Quote.QuoteNumber` |
| `AccountName` | `Quote.Account.Name` |
| `CreatedDate` | `Quote.CreatedDate` (formatted: "7 October 2026") |
| `ExpirationDate` | `Quote.ExpirationDate` (formatted) |
| `GrandTotal` | `Quote.GrandTotal` (formatted: "$1,234.56") |
| `SalesRep` | `User.Name` (Quote owner) |
| `SellerEmail` | `User.Email` |
| `SellerPhone` | `User.Phone` |
| `SellerFax` | `User.Fax` |
| `BillingStreet` | `Quote.BillingStreet` |
| `BillingCity` | `Quote.BillingCity` |
| `BillingState` | `Quote.BillingState` |
| `BillingPostalCode` | `Quote.BillingPostalCode` |
| `RampSegments` | List — see below |

### RampSegments List Fields
Each entry in `RampSegments`:

| Key | Source |
|-----|--------|
| `SegmentName` | `QuoteLineGroup.Name` |
| `StartDate` | `QuoteLineGroup.StartDate` (formatted) |
| `EndDate` | `QuoteLineGroup.EndDate` (formatted) |
| `SegmentSubTotal` | Sum of `NetTotalPrice` for all lines in segment |
| `Line` | List of line items — see below |
| `HasUsageLines` | Boolean — true if any usage products in segment |
| `UsageLines` | List of usage lines — see below |

### Line Fields (within RampSegments.Line)
| Key | Source |
|-----|--------|
| `ProductName` | `QuoteLineItem.Product2.Name` (appends `**` if usage anchor) |
| `Quantity` | `QuoteLineItem.Quantity` (integer string) |
| `ListPrice` | `QuoteLineItem.UnitPrice` (formatted currency) |
| `Discount` | `QuoteLineItem.Discount` (e.g., "10.00%") |
| `NetUnitPrice` | `QuoteLineItem.NetUnitPrice` (formatted currency) |
| `NetTotalPrice` | `QuoteLineItem.NetTotalPrice` (formatted currency) |
| `BillingFrequency` | `QuoteLineItem.BillingFrequency` |

### UsageLines Fields (within RampSegments.UsageLines)
| Key | Source |
|-----|--------|
| `AnchorProduct` | `QuoteLineItem.Product2.Name` |
| `Uom` | `ProductUsageGrant.UsageRsrc.Name` |
| `BillingFrequency` | `QuoteLineItem.BillingFrequency` |
| `AggregationMethod` | Always `"Sum"` |
| `ValidityPeriod` | `ProductUsageGrant.ValidityPeriodUnit` |
| `OverageChargeable` | `ProductUsageGrant.OverageChargeable` |
| `GrantDisplay` | `Quantity × PUG.Quantity` (formatted number, e.g., "10,000") |
| `OverageRate` | Negotiated from `QuoteLineRateCardEntry`, fallback from `RateCardEntry` (e.g., "$0.015/unit" or "TBD") |

---

## Key Salesforce Objects

| Object | Purpose |
|--------|---------|
| `QuoteLineGroup` | Ramp segment (StartDate/EndDate) |
| `QuoteLineItem` | Quote line; `QuoteLineGroupId` assigns it to a segment |
| `ProductUsageGrant` | Per-unit included usage grant; `Status = 'Active'` |
| `ProductUsageResource` | Links `Product2` to `UsageResource` records |
| `UsageResource` | Usage resource definition (e.g., "API Calls") |
| `QuoteLineRateCardEntry` | Negotiated overage rate at quote line level |
| `RateCardEntry` | Catalog overage rate (fallback; `RateCardType = 'Base'`) |
| `QuotLineItmUsersrcGrant` | Line-level grant override (written by "Manage Usage Resources" UI) |
| `DocumentTemplate` | The DocGen template; looked up by `System.Label.RlmDocGenTemplateName` |
| `DocumentTemplateContentDoc` | Links template to its content version |
| `DocumentGenerationProcess` | The async job record; `TokenData` field carries all merge data |

---

## Template Lookup

The assembler looks up the `DocumentTemplate` by Name:

```apex
DocumentTemplate dt = [
    SELECT Id FROM DocumentTemplate
    WHERE Name = :System.Label.RlmDocGenTemplateName
    LIMIT 1
];
```

The Custom Label `RlmDocGenTemplateName` defaults to `RLM Ramp Deal Proposal`. Update the label value in Setup → Custom Labels after deploying if your template has a different name.

---

## Components

| Component | Purpose |
|-----------|---------|
| `RlmRampDocGenController` | `@AuraEnabled` entry point; delegates to assembler |
| `RlmRampTokenAssembler` | Builds `tokenData`, creates `DocumentGenerationProcess` |
| `RlmUsageLineBuilder` | `@InvocableMethod` for building usage lines from JSON inputs (Flow-callable) |
| `RlmUsageGrantController` | `@AuraEnabled` for live usage wallet preview on Quote record |
| `rlmRampDocGen` LWC | Quick Action button on Quote; triggers doc generation |
| `rlmUsageGrantSummary` LWC | Wallet preview bar on Quote record page; shows included usage and overage |

### rlmUsageGrantSummary Behavior

- Shown only when the quote has **no** `QuoteLineGroup` records (non-ramp quotes)
- For ramp quotes, the component hides itself (ramp context is document-only)
- Shows a collapsed bar with first product's grant summary; expand to see all products
- Negotiate Grant/Overage modal is NOT included — that is a further customization opportunity

---

## Development Patterns

### Adding a Header Field

```apex
// In RlmRampTokenAssembler.assembleTokenData():
// 1. Add to SOQL: SELECT ..., MyCustomField__c FROM Quote WHERE Id = :quoteId
// 2. Add to tokenData map:
tokenData.put('MyCustomField', q.MyCustomField__c != null ? q.MyCustomField__c : '');
```

Then add `{{MyCustomField}}` merge field to the .docx template.

### Adding a Per-Line Field

```apex
// In QuoteLineItem SOQL, add field:
SELECT ..., MyCustomField__c FROM QuoteLineItem WHERE QuoteId = :quoteId

// In linesList.add() call, add key:
'MyCustomField' => qli.MyCustomField__c != null ? String.valueOf(qli.MyCustomField__c) : ''
```

### Adding a Per-Usage-Line Field

```apex
// Ensure ProductUsageGrant SOQL includes the field:
SELECT ..., MyNewField__c FROM ProductUsageGrant WHERE Status = 'Active'

// In usageLines.add() call, add key:
'MyNewField' => pug.MyNewField__c != null ? String.valueOf(pug.MyNewField__c) : ''
```

---

## Key File Locations

```
DOCGEN_RAMP_USAGE/
├── force-app/main/default/
│   ├── classes/
│   │   ├── RlmRampDocGenController.cls       ← AuraEnabled entry point
│   │   ├── RlmRampTokenAssembler.cls         ← Core data assembly + DGP insert
│   │   ├── RlmUsageLineBuilder.cls           ← Invocable usage line builder (Flow)
│   │   └── RlmUsageGrantController.cls       ← Live wallet preview queries
│   ├── labels/
│   │   └── CustomLabels.labels-meta.xml      ← RlmDocGenTemplateName label
│   └── lwc/
│       ├── rlmRampDocGen/                    ← Quick Action button component
│       └── rlmUsageGrantSummary/             ← Wallet preview bar component
├── config/project-scratch-def.json
├── sfdx-project.json
└── CLAUDE.md
```

---

## Owner

jrunnels@salesforce.com
