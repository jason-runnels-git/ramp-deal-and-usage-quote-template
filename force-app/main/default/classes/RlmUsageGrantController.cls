public with sharing class RlmUsageGrantController {

    public class UsageGrantRow {
        @AuraEnabled public String productId;
        @AuraEnabled public String qliId;
        @AuraEnabled public String usageResourceId;
        @AuraEnabled public String qlrceId;
        @AuraEnabled public String rceId;
        @AuraEnabled public String productName;
        @AuraEnabled public String resourceName;
        @AuraEnabled public Decimal perUnitGrant;
        @AuraEnabled public Decimal quoteLineQty;
        @AuraEnabled public Decimal totalGrant;
        @AuraEnabled public Decimal overageRate;
        @AuraEnabled public Boolean isTiered;
        @AuraEnabled public String billingPeriod;
    }

    @AuraEnabled(cacheable=true)
    public static Boolean quoteHasGroups(Id quoteId) {
        return [SELECT COUNT() FROM QuoteLineGroup WHERE QuoteId = :quoteId LIMIT 1] > 0;
    }

    @AuraEnabled(cacheable=false)
    public static List<UsageGrantRow> getUsageGrantSummary(Id quoteId) {
        List<QuoteLineItem> lines = [
            SELECT Id, Quantity, Product2Id, Product2.Name, ProductSellingModelId
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            AND Product2.UsageModelType = 'Anchor'
        ];

        if (lines.isEmpty()) return new List<UsageGrantRow>();

        Set<Id> productIds = new Set<Id>();
        Set<Id> qliIds = new Set<Id>();
        Set<Id> psmIds = new Set<Id>();
        Map<Id, Decimal> qtyByProduct = new Map<Id, Decimal>();
        Map<Id, String> nameByProduct = new Map<Id, String>();
        Map<Id, Id> psmByProduct = new Map<Id, Id>();
        Map<Id, Id> qliByProduct = new Map<Id, Id>();
        for (QuoteLineItem qli : lines) {
            productIds.add(qli.Product2Id);
            qliIds.add(qli.Id);
            qtyByProduct.put(qli.Product2Id, qli.Quantity);
            nameByProduct.put(qli.Product2Id, qli.Product2.Name);
            qliByProduct.put(qli.Product2Id, qli.Id);
            if (qli.ProductSellingModelId != null) {
                psmIds.add(qli.ProductSellingModelId);
                psmByProduct.put(qli.Product2Id, qli.ProductSellingModelId);
            }
        }

        Map<Id, String> billingPeriodByPsm = new Map<Id, String>();
        for (ProductSellingModel psm : [
            SELECT Id, PricingTerm, PricingTermUnit
            FROM ProductSellingModel
            WHERE Id IN :psmIds
        ]) {
            String raw = psm.PricingTermUnit != null ? psm.PricingTermUnit.toLowerCase() : 'month';
            String unit = raw.startsWith('month') ? 'month' : raw.startsWith('year') ? 'year' : raw.startsWith('day') ? 'day' : raw;
            billingPeriodByPsm.put(psm.Id, 'per ' + unit);
        }

        List<ProductUsageResource> purs = [
            SELECT Id, ProductId, UsageResourceId
            FROM ProductUsageResource
            WHERE ProductId IN :productIds
            AND Status = 'Active'
        ];

        if (purs.isEmpty()) return new List<UsageGrantRow>();

        Set<Id> purIds = new Set<Id>();
        Set<Id> resourceIds = new Set<Id>();
        Map<Id, ProductUsageResource> purById = new Map<Id, ProductUsageResource>();
        Map<String, Id> purByProductResource = new Map<String, Id>();
        for (ProductUsageResource pur : purs) {
            purIds.add(pur.Id);
            resourceIds.add(pur.UsageResourceId);
            purById.put(pur.Id, pur);
            purByProductResource.put(pur.ProductId + '_' + pur.UsageResourceId, pur.Id);
        }

        Map<Id, String> nameByResource = new Map<Id, String>();
        for (UsageResource ur : [SELECT Id, Name FROM UsageResource WHERE Id IN :resourceIds]) {
            nameByResource.put(ur.Id, ur.Name);
        }

        Map<Id, Decimal> catalogGrantByPur = new Map<Id, Decimal>();
        for (ProductUsageGrant pug : [
            SELECT Id, ProductUsageResourceId, Quantity, UsageModelType
            FROM ProductUsageGrant
            WHERE ProductUsageResourceId IN :purIds
            AND Status = 'Active'
        ]) {
            ProductUsageResource pur = purById.get(pug.ProductUsageResourceId);
            Decimal lineQty = pur != null ? (qtyByProduct.get(pur.ProductId) ?? 1) : 1;
            Decimal effective = pug.UsageModelType == 'Pack' ? pug.Quantity : pug.Quantity * lineQty;
            Decimal existing = catalogGrantByPur.get(pug.ProductUsageResourceId) ?? 0;
            catalogGrantByPur.put(pug.ProductUsageResourceId, existing + effective);
        }

        Map<String, Decimal> overrideGrantByQliResource = new Map<String, Decimal>();
        for (QuotLineItmUsersrcGrant qliug : [
            SELECT QuoteLineItemId, UsageResourceId, GrantQuantity
            FROM QuotLineItmUsersrcGrant
            WHERE QuoteLineItemId IN :qliIds
        ]) {
            overrideGrantByQliResource.put(
                qliug.QuoteLineItemId + '_' + qliug.UsageResourceId,
                qliug.GrantQuantity
            );
        }

        Map<String, Decimal> overageByProductResource = new Map<String, Decimal>();
        Map<String, Integer> overageCountByProductResource = new Map<String, Integer>();
        Map<String, String> rceIdByProductResource = new Map<String, String>();
        for (RateCardEntry rce : [
            SELECT Id, ProductId, UsageResourceId, ProductSellingModelId, Rate
            FROM RateCardEntry
            WHERE ProductId IN :productIds
            AND UsageResourceId IN :resourceIds
            AND (ProductSellingModelId IN :psmIds OR ProductSellingModelId = null)
            AND Status = 'Active'
        ]) {
            String key = rce.ProductId + '_' + rce.UsageResourceId + '_' + rce.ProductSellingModelId;
            Integer cnt = overageCountByProductResource.get(key);
            overageCountByProductResource.put(key, cnt == null ? 1 : cnt + 1);
            overageByProductResource.put(key, rce.Rate);
            rceIdByProductResource.put(key, rce.Id);
        }

        Map<String, Decimal> overrideRateByQliResource = new Map<String, Decimal>();
        Map<String, String> qlrceIdByQliResource = new Map<String, String>();
        for (QuoteLineRateCardEntry qlrce : [
            SELECT Id, QuoteLineItemId, UsageResourceId, NegotiatedRate
            FROM QuoteLineRateCardEntry
            WHERE QuoteLineItemId IN :qliIds
            AND UsageResourceId IN :resourceIds
        ]) {
            String k = qlrce.QuoteLineItemId + '_' + qlrce.UsageResourceId;
            overrideRateByQliResource.put(k, qlrce.NegotiatedRate);
            qlrceIdByQliResource.put(k, qlrce.Id);
        }

        List<UsageGrantRow> rows = new List<UsageGrantRow>();
        for (ProductUsageResource pur : purs) {
            Id productId = pur.ProductId;
            Id qliId = qliByProduct.get(productId);

            Decimal lineQty = qtyByProduct.get(productId);
            String overrideKey = qliId + '_' + pur.UsageResourceId;
            Decimal totalGrant;
            if (overrideGrantByQliResource.containsKey(overrideKey)) {
                totalGrant = overrideGrantByQliResource.get(overrideKey) * lineQty;
            } else {
                totalGrant = catalogGrantByPur.get(pur.Id);
            }

            if (totalGrant == null) continue;

            UsageGrantRow row = new UsageGrantRow();
            row.productId = productId;
            row.qliId = qliId;
            row.usageResourceId = pur.UsageResourceId;
            row.qlrceId = qlrceIdByQliResource.get(overrideKey);
            row.productName = nameByProduct.get(productId);
            row.resourceName = nameByResource.get(pur.UsageResourceId);
            row.perUnitGrant = null;
            row.quoteLineQty = lineQty;
            row.totalGrant = totalGrant;
            String rateOverrideKey = qliId + '_' + pur.UsageResourceId;
            Id psmId2 = psmByProduct.get(productId);
            String catalogRateKey = productId + '_' + pur.UsageResourceId + '_' + psmId2;
            if (!overageByProductResource.containsKey(catalogRateKey)) {
                catalogRateKey = productId + '_' + pur.UsageResourceId + '_null';
            }
            row.rceId = rceIdByProductResource.get(catalogRateKey);
            if (overrideRateByQliResource.containsKey(rateOverrideKey)) {
                row.overageRate = overrideRateByQliResource.get(rateOverrideKey);
                row.isTiered = false;
            } else {
                Integer rceCount = overageCountByProductResource.get(catalogRateKey);
                row.isTiered = rceCount != null && rceCount > 1;
                row.overageRate = row.isTiered ? null : overageByProductResource.get(catalogRateKey);
            }
            Id psmIdForBilling = psmByProduct.get(productId);
            row.billingPeriod = psmIdForBilling != null && billingPeriodByPsm.containsKey(psmIdForBilling)
                ? billingPeriodByPsm.get(psmIdForBilling)
                : 'per month';
            rows.add(row);
        }

        return rows;
    }
}
