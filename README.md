# RLM DocGen — Ramp Quotes & Usage-Based Products

Salesforce Revenue Cloud (RLM) document generation for ramp quotes and usage-based products. Deploy this SFDX project to add a "Generate Ramp Proposal" Quick Action to your Quote page that produces a formatted PDF proposal using Salesforce Document Generation.

---

## What This Does

- **Ramp proposal generation**: Produces a `.docx`/PDF deal proposal from a Quote with ramp segments (`QuoteLineGroup` records), including per-segment line items, subtotals, and usage grant summaries.
- **Usage wallet preview**: A live component on the Quote record page that shows included usage grants and overage rates for anchor products (non-ramp quotes).

---

## Prerequisites

Your Salesforce org must have:

- **Revenue Lifecycle Management (RLM)** enabled
- **OmniStudio** installed (required by RLM)
- **Document Generation** feature enabled (Setup → Document Generation Settings)
- API version 66.0+ (Summer '25 or later)

---

## Deployment Steps

### 1. Clone and deploy metadata

```bash
git clone <this-repo>
cd rlm-docgen-ramp-usage
sf project deploy start --source-dir force-app
```

This deploys:
- 4 Apex classes
- 2 LWC components
- 1 Custom Label (`RlmDocGenTemplateName`)

### 2. Create the Document Template

1. In Salesforce Setup, go to **Document Generation Templates**
2. Create a new template named exactly **`RLM Ramp Deal Proposal`**
3. Upload your `.docx` file with the merge fields listed in the Merge Field Reference below
4. Set the template's **Object** to `Quote`
5. If prompted to map an Integration Procedure, you may do so for the standard "Generate Document" button — it does not affect the custom Apex flow

> **Template name mismatch?** If you use a different template name, update the Custom Label: Setup → Custom Labels → `RlmDocGenTemplateName` → Edit value.

### 3. Add the Quick Action to Quote

1. Setup → Object Manager → **Quote** → Buttons, Links, and Actions → **New Action**
2. Action Type: **Lightning Component**
3. Lightning Component: `c:rlmRampDocGen`
4. Label: `Generate Ramp Proposal`
5. Save, then add the action to the **Quote Page Layout** under Quick Actions

### 4. Add the Usage Wallet to the Quote Record Page (optional)

1. Open any Quote record → click the gear icon → **Edit Page**
2. Find `rlmUsageGrantSummary` in the Components panel
3. Drop it onto the Quote record page layout
4. Save and Activate

---

## How to Extend — Adding New Fields

The key rule: **fields render if and only if they exist in the `tokenData` map in Apex AND as a merge field in the `.docx` template.**

The Integration Procedure wired to the Document Template in Setup is used by the standard Generate Document button, not by this project's Apex flow. Do not edit the IP to change what data appears.

### Adding a new header field

**Step 1** — In `RlmRampTokenAssembler.cls`, add to the Quote SOQL query:
```apex
SELECT ..., MyNewField__c FROM Quote WHERE Id = :quoteId
```

**Step 2** — Add the key to the `tokenData` map:
```apex
tokenData.put('MyNewField', q.MyNewField__c != null ? String.valueOf(q.MyNewField__c) : '');
```

**Step 3** — Add `{{MyNewField}}` merge field to your `.docx` template.

### Adding a new per-line field

**Step 1** — Add the field to the `QuoteLineItem` SOQL:
```apex
SELECT ..., MyLineField__c FROM QuoteLineItem WHERE QuoteId = :quoteId
```

**Step 2** — Add to the `linesList.add(...)` map in the segment loop:
```apex
'MyLineField' => qli.MyLineField__c != null ? String.valueOf(qli.MyLineField__c) : ''
```

**Step 3** — Add `{{MyLineField}}` inside the `{Line}` repeating section of your template.

### Adding a new usage line field

**Step 1** — Add the field to the `ProductUsageGrant` SOQL:
```apex
SELECT ..., MyUsageField__c FROM ProductUsageGrant WHERE Status = 'Active'
```

**Step 2** — Add to the `usageLines.add(...)` map:
```apex
'MyUsageField' => pug.MyUsageField__c != null ? String.valueOf(pug.MyUsageField__c) : ''
```

**Step 3** — Add `{{MyUsageField}}` inside the `{UsageLines}` repeating section of your template.

---

## Merge Field Reference

Use these token names as merge fields in your `.docx` template.

### Quote Header
`{{QuoteName}}` `{{QuoteNumber}}` `{{AccountName}}` `{{CreatedDate}}` `{{ExpirationDate}}` `{{GrandTotal}}`  
`{{SalesRep}}` `{{SellerEmail}}` `{{SellerPhone}}` `{{SellerFax}}`  
`{{BillingStreet}}` `{{BillingCity}}` `{{BillingState}}` `{{BillingPostalCode}}`

### Ramp Segments (repeating section: `{RampSegments}`)
`{{SegmentName}}` `{{StartDate}}` `{{EndDate}}` `{{SegmentSubTotal}}`

### Line Items (repeating section within segment: `{Line}`)
`{{ProductName}}` `{{Quantity}}` `{{ListPrice}}` `{{Discount}}` `{{NetUnitPrice}}` `{{NetTotalPrice}}` `{{BillingFrequency}}`

### Usage Lines (repeating section within segment: `{UsageLines}`, conditional on `{{HasUsageLines}}`)
`{{AnchorProduct}}` `{{Uom}}` `{{GrantDisplay}}` `{{OverageRate}}` `{{BillingFrequency}}` `{{ValidityPeriod}}` `{{OverageChargeable}}` `{{AggregationMethod}}`

---

## Architecture Overview

```
Quote Record Page
    │
    ├── Quick Action: rlmRampDocGen (LWC)
    │       │
    │       └── RlmRampDocGenController.generateProposal(quoteId)
    │               │
    │               └── RlmRampTokenAssembler.assembleTokenData(quoteId)
    │                       │
    │                       ├── SOQL: Quote, QuoteLineGroup, QuoteLineItem
    │                       ├── SOQL: ProductUsageGrant, QuoteLineRateCardEntry, RateCardEntry
    │                       ├── Builds tokenData Map<String,Object>
    │                       ├── Looks up DocumentTemplate by Custom Label name
    │                       └── Inserts DocumentGenerationProcess (DGP)
    │                               │
    │                               └── DGP.TokenData ──→ DocGen Engine ──→ .docx/.pdf
    │
    └── Component: rlmUsageGrantSummary (LWC, non-ramp quotes only)
            │
            └── RlmUsageGrantController.getUsageGrantSummary(quoteId)
                    │
                    └── SOQL: ProductUsageResource, ProductUsageGrant, RateCardEntry,
                              QuoteLineRateCardEntry, QuotLineItmUsersrcGrant
```

### Why custom Apex instead of IP-driven DocGen?

The IP-driven flow (standard "Generate Document" button) collects data declaratively and is harder to customize for complex nested structures like ramp segments with per-segment usage lines. The Apex approach allows full control over the `tokenData` payload structure and makes it easy to add/remove fields without touching IP configuration.

---

## Further Customizations

- **Negotiate Grant/Overage Modal** — the `rlmUsageGrantSummary` component includes hooks for a negotiation modal (to set `QuoteLineRateCardEntry` / `QuotLineItmUsersrcGrant` overrides). The modal component itself is not included in this package; see the Klaviyo-262 reference project for an implementation example.
- **Non-ramp single-page quote** — if your quotes don't use `QuoteLineGroup`, the `RampSegments` array will be empty. You can adapt the template to render a flat line item table instead, or add a non-ramp `Line` list at the header level in `assembleTokenData()`.
- **Multiple templates** — add additional Custom Labels and controller entry points to support separate templates for, e.g., order proposals vs. quote proposals.

---

## Owner

jrunnels@salesforce.com
