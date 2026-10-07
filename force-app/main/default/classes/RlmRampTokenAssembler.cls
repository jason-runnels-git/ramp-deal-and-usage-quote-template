// To add a new field: (1) add a key to tokenData in assembleTokenData(),
// (2) add the matching merge field to the DocumentTemplate .docx.
// The IP wired to the template in Setup is not involved in field rendering.
public without sharing class RlmRampTokenAssembler implements System.Callable {

    public Object call(String action, Map<String, Object> args) {
        if (action == 'assembleTokenData') {
            String quoteId = (String) args.get('quoteId');
            try {
                return assembleTokenData(quoteId);
            } catch (Exception e) {
                return new Map<String, Object>{
                    'error' => e.getMessage(),
                    'stackTrace' => e.getStackTraceString()
                };
            }
        }
        throw new IllegalArgumentException('Unknown action: ' + action);
    }

    private Map<String, Object> assembleTokenData(String quoteId) {
        Quote q = [
            SELECT Name, QuoteNumber, CreatedDate, ExpirationDate, GrandTotal,
                   Account.Name, BillingStreet, BillingCity, BillingState, BillingPostalCode,
                   OwnerId
            FROM Quote WHERE Id = :quoteId LIMIT 1
        ];
        User owner = [SELECT Name, Email, Phone, Fax FROM User WHERE Id = :q.OwnerId LIMIT 1];

        List<QuoteLineGroup> segments = [
            SELECT Id, Name, StartDate, EndDate
            FROM QuoteLineGroup
            WHERE QuoteId = :quoteId
            ORDER BY StartDate ASC NULLS LAST
        ];

        List<QuoteLineItem> lineItems = [
            SELECT Id, Product2Id, Product2.Name, Quantity, UnitPrice, NetUnitPrice, NetTotalPrice,
                   Discount, QuoteLineGroupId, BillingFrequency
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
        ];

        // PUG data: ProductId → all active PUGs (one per usage resource)
        Map<Id, List<ProductUsageGrant>> pugsByProductId = new Map<Id, List<ProductUsageGrant>>();
        for (ProductUsageGrant pug : [
            SELECT ProductId, Quantity, UsageRsrcId, UsageRsrc.Name, ValidityPeriodUnit, OverageChargeable
            FROM ProductUsageGrant WHERE Status = 'Active'
        ]) {
            if (!pugsByProductId.containsKey(pug.ProductId)) {
                pugsByProductId.put(pug.ProductId, new List<ProductUsageGrant>());
            }
            pugsByProductId.get(pug.ProductId).add(pug);
        }
        Set<Id> usageProductIds = pugsByProductId.keySet();

        // Negotiated overage rates: keyed by lineItemId:usageResourceId
        Map<String, Decimal> negotiatedRates = new Map<String, Decimal>();
        for (QuoteLineRateCardEntry qlrce : [
            SELECT QuoteLineItemId, UsageResourceId, NegotiatedRate
            FROM QuoteLineRateCardEntry
            WHERE QuoteLineItem.QuoteId = :quoteId
        ]) {
            String rk = qlrce.QuoteLineItemId + ':' + qlrce.UsageResourceId;
            if (!negotiatedRates.containsKey(rk)) {
                negotiatedRates.put(rk, qlrce.NegotiatedRate);
            }
        }

        // Fallback product-level rates: keyed by productId:usageResourceId
        Map<String, Decimal> fallbackRates = new Map<String, Decimal>();
        for (RateCardEntry rce : [
            SELECT ProductId, UsageResourceId, Rate
            FROM RateCardEntry WHERE RateCardType = 'Base'
        ]) {
            String rk = rce.ProductId + ':' + rce.UsageResourceId;
            if (!fallbackRates.containsKey(rk)) {
                fallbackRates.put(rk, rce.Rate);
            }
        }

        Map<Id, List<QuoteLineItem>> linesByGroup = new Map<Id, List<QuoteLineItem>>();
        for (QuoteLineItem qli : lineItems) {
            if (qli.QuoteLineGroupId != null) {
                if (!linesByGroup.containsKey(qli.QuoteLineGroupId)) {
                    linesByGroup.put(qli.QuoteLineGroupId, new List<QuoteLineItem>());
                }
                linesByGroup.get(qli.QuoteLineGroupId).add(qli);
            }
        }

        List<Map<String, Object>> rampSegments = new List<Map<String, Object>>();
        for (QuoteLineGroup seg : segments) {
            List<QuoteLineItem> segLines = linesByGroup.get(seg.Id);
            if (segLines == null || segLines.isEmpty()) continue;

            List<Map<String, Object>> linesList = new List<Map<String, Object>>();
            Decimal segSubTotal = 0;
            for (QuoteLineItem qli : segLines) {
                Decimal netTotal = qli.NetTotalPrice != null ? qli.NetTotalPrice : 0;
                segSubTotal += netTotal;
                Boolean isUsage = usageProductIds.contains(qli.Product2Id);
                linesList.add(new Map<String, Object>{
                    'ProductName'      => qli.Product2?.Name + (isUsage ? '**' : ''),
                    'Quantity'         => qli.Quantity != null ? String.valueOf(qli.Quantity.intValue()) : '1',
                    'ListPrice'        => formatCurrency(qli.UnitPrice),
                    'Discount'         => qli.Discount != null ? String.valueOf(qli.Discount.setScale(2)) + '%' : '0%',
                    'NetUnitPrice'     => formatCurrency(qli.NetUnitPrice),
                    'NetTotalPrice'    => formatCurrency(netTotal),
                    'BillingFrequency' => qli.BillingFrequency != null ? qli.BillingFrequency : ''
                });
            }

            List<Map<String, Object>> usageLines = new List<Map<String, Object>>();
            for (QuoteLineItem qli : segLines) {
                List<ProductUsageGrant> pugs = pugsByProductId.get(qli.Product2Id);
                if (pugs == null || pugs.isEmpty()) continue;

                for (ProductUsageGrant pug : pugs) {
                    Decimal grantDisplay = (qli.Quantity != null ? qli.Quantity : 1)
                                         * (pug.Quantity != null ? pug.Quantity : 0);

                    String rk = qli.Id + ':' + pug.UsageRsrcId;
                    Decimal rate = negotiatedRates.get(rk);
                    if (rate == null) {
                        rate = fallbackRates.get(qli.Product2Id + ':' + pug.UsageRsrcId);
                    }

                    String uom = pug.UsageRsrc?.Name != null ? pug.UsageRsrc.Name : 'Unit';

                    usageLines.add(new Map<String, Object>{
                        'AnchorProduct'      => qli.Product2?.Name,
                        'Uom'                => uom,
                        'BillingFrequency'   => qli.BillingFrequency != null ? qli.BillingFrequency : '',
                        'AggregationMethod'  => 'Sum',
                        'ValidityPeriod'     => pug.ValidityPeriodUnit != null ? pug.ValidityPeriodUnit : '',
                        'OverageChargeable'  => pug.OverageChargeable != null ? pug.OverageChargeable : '',
                        'GrantDisplay'       => formatNumber(grantDisplay),
                        'OverageRate'        => rate != null ? '$' + formatRate(rate) + '/unit' : 'TBD'
                    });
                }
            }

            rampSegments.add(new Map<String, Object>{
                'SegmentName'     => seg.Name,
                'StartDate'       => formatDate(seg.StartDate),
                'EndDate'         => formatDate(seg.EndDate),
                'Line'            => linesList,
                'HasUsageLines'   => !usageLines.isEmpty(),
                'UsageLines'      => usageLines,
                'SegmentSubTotal' => formatCurrency(segSubTotal)
            });
        }

        Map<String, Object> tokenData = new Map<String, Object>{
            'QuoteName'         => q.Name,
            'QuoteNumber'       => q.QuoteNumber,
            'AccountName'       => q.Account?.Name,
            'CreatedDate'       => formatDateTime(q.CreatedDate),
            'ExpirationDate'    => formatDate(q.ExpirationDate),
            'GrandTotal'        => formatCurrency(q.GrandTotal),
            'SalesRep'          => owner.Name,
            'SellerEmail'       => owner.Email,
            'SellerPhone'       => owner.Phone != null ? owner.Phone : '',
            'SellerFax'         => owner.Fax != null ? owner.Fax : '',
            'BillingStreet'     => q.BillingStreet,
            'BillingCity'       => q.BillingCity,
            'BillingState'      => q.BillingState,
            'BillingPostalCode' => q.BillingPostalCode,
            'RampSegments'      => rampSegments
        };

        DocumentTemplate dt = [
            SELECT Id FROM DocumentTemplate
            WHERE Name = :System.Label.RlmDocGenTemplateName
            LIMIT 1
        ];
        DocumentTemplateContentDoc dtcd = [
            SELECT LatestContentVersionId FROM DocumentTemplateContentDoc
            WHERE DocumentTemplateId = :dt.Id LIMIT 1
        ];

        DocumentGenerationProcess dgp = new DocumentGenerationProcess();
        dgp.Type = 'GenerateAndConvert';
        Integer versionNum = 1;
        List<ContentVersion> existing = [
            SELECT Id FROM ContentVersion
            WHERE Title LIKE :('RLM Ramp Deal Proposal - ' + q.QuoteNumber + '%')
            ORDER BY CreatedDate ASC
        ];
        if (!existing.isEmpty()) versionNum = (existing.size() / 2) + 1;

        dgp.RequestText = JSON.serialize(new Map<String, Object>{
            'keepIntermediate' => true,
            'title'            => 'RLM Ramp Deal Proposal - ' + q.QuoteNumber + ' - v' + versionNum,
            'templateContentVersionId' => dtcd.LatestContentVersionId
        });
        dgp.ReferenceObject      = quoteId;
        dgp.TokenData            = JSON.serialize(tokenData);
        dgp.DocGenApiVersionType = 'Advanced';
        insert dgp;

        return new Map<String, Object>{ 'jobId' => dgp.Id };
    }

    private static final List<String> MONTHS = new List<String>{
        'January','February','March','April','May','June',
        'July','August','September','October','November','December'
    };

    private static String formatDate(Date d) {
        if (d == null) return '';
        return String.valueOf(d.day()) + ' ' + MONTHS[d.month() - 1] + ' ' + String.valueOf(d.year());
    }

    private static String formatDateTime(DateTime dt) {
        if (dt == null) return '';
        Date d = dt.dateGMT();
        return String.valueOf(d.day()) + ' ' + MONTHS[d.month() - 1] + ' ' + String.valueOf(d.year());
    }

    private static String formatNumber(Decimal d) {
        if (d == null) return '0';
        String s = String.valueOf(d.longValue());
        String out = '';
        Integer rem = Math.mod(s.length(), 3);
        for (Integer i = 0; i < s.length(); i++) {
            if (i > 0 && rem > 0 && Math.mod(i - rem, 3) == 0) out += ',';
            else if (i > 0 && rem == 0 && Math.mod(i, 3) == 0) out += ',';
            out += s.substring(i, i + 1);
        }
        return out;
    }

    private static String formatRate(Decimal rate) {
        if (rate == null) return '0.000';
        return rate.setScale(3).toPlainString()
            .replaceAll('(\\.[0-9]*[1-9])0+$', '$1')
            .replaceAll('\\.0+$', '.00');
    }

    private static String formatCurrency(Decimal amt) {
        if (amt == null) return '$0.00';
        amt = amt.setScale(2);
        Long whole = amt.longValue();
        Decimal fracPart = amt - Decimal.valueOf(whole);
        Integer cents = (fracPart * 100).intValue();
        String dec = cents < 10 ? '0' + String.valueOf(cents) : String.valueOf(cents);
        String s = String.valueOf(whole);
        String out = '';
        Integer rem = Math.mod(s.length(), 3);
        for (Integer i = 0; i < s.length(); i++) {
            if (i > 0 && rem > 0 && Math.mod(i - rem, 3) == 0) out += ',';
            else if (i > 0 && rem == 0 && Math.mod(i, 3) == 0) out += ',';
            out += s.substring(i, i + 1);
        }
        return '$' + out + '.' + dec;
    }
}
