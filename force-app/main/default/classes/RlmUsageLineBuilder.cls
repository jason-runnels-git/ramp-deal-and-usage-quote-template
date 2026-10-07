public with sharing class RlmUsageLineBuilder {

    public class BuildRequest {
        @InvocableVariable(required=true)
        public String linesJson;
        @InvocableVariable(required=true)
        public String pugsJson;
        @InvocableVariable(required=true)
        public String negotiatedRatesJson;
        @InvocableVariable(required=true)
        public String fallbackRatesJson;
    }

    public class BuildResult {
        @InvocableVariable
        public String usageLinesJson;
    }

    public class LineInput {
        public String quoteLineItemId;
        public String product2Id;
        public String groupId;
        public Decimal quantity;
        public String productName;
    }

    public class PugInput {
        public String productId;
        public Decimal grantQty;
        public String usageResourceName;
        public String validityPeriodUnit;
        public String overageChargeable;
        public String accumulationPeriod;
    }

    public class NegotiatedRateInput {
        public String quoteLineItemId;
        public Decimal negotiatedRate;
        public String usageResourceId;
    }

    public class FallbackRateInput {
        public String productId;
        public Decimal rate;
        public String rateUomName;
    }

    public class UsageLineOutput {
        public String quoteLineItemId;
        public String groupId;
        public String anchorProductName;
        public String grantDisplay;
        public String uom;
        public String overageRate;
        public String billingFrequency;
        public String aggregationMethod;
        public String validityPeriod;
        public String overageChargeable;
    }

    @InvocableMethod(label='Build Usage Lines for Ramp Quote')
    public static List<BuildResult> buildUsageLines(List<BuildRequest> requests) {
        List<BuildResult> results = new List<BuildResult>();
        for (BuildRequest req : requests) {
            results.add(process(req));
        }
        return results;
    }

    private static BuildResult process(BuildRequest req) {
        List<LineInput> lines = (List<LineInput>) JSON.deserialize(req.linesJson, List<LineInput>.class);
        List<PugInput> pugs = (List<PugInput>) JSON.deserialize(req.pugsJson, List<PugInput>.class);
        List<NegotiatedRateInput> negotiatedRates = (List<NegotiatedRateInput>) JSON.deserialize(req.negotiatedRatesJson, List<NegotiatedRateInput>.class);
        List<FallbackRateInput> fallbackRates = (List<FallbackRateInput>) JSON.deserialize(req.fallbackRatesJson, List<FallbackRateInput>.class);

        Map<String, PugInput> pugByProductId = new Map<String, PugInput>();
        for (PugInput pug : pugs) {
            pugByProductId.put(pug.productId, pug);
        }

        Map<String, NegotiatedRateInput> negotiatedByLineId = new Map<String, NegotiatedRateInput>();
        for (NegotiatedRateInput nr : negotiatedRates) {
            if (!negotiatedByLineId.containsKey(nr.quoteLineItemId)) {
                negotiatedByLineId.put(nr.quoteLineItemId, nr);
            }
        }

        Map<String, FallbackRateInput> fallbackByProductId = new Map<String, FallbackRateInput>();
        for (FallbackRateInput fr : fallbackRates) {
            if (!fallbackByProductId.containsKey(fr.productId)) {
                fallbackByProductId.put(fr.productId, fr);
            }
        }

        List<UsageLineOutput> outputLines = new List<UsageLineOutput>();

        for (LineInput line : lines) {
            PugInput pug = pugByProductId.get(line.product2Id);
            if (pug == null) continue;

            UsageLineOutput out = new UsageLineOutput();
            out.quoteLineItemId  = line.quoteLineItemId;
            out.groupId          = line.groupId;
            out.anchorProductName = line.productName;
            out.uom              = pug.usageResourceName;
            out.billingFrequency = pug.accumulationPeriod;
            out.aggregationMethod = 'Sum'.equals(pug.accumulationPeriod) ? 'Sum' : pug.accumulationPeriod;
            out.validityPeriod   = pug.validityPeriodUnit;
            out.overageChargeable = pug.overageChargeable;

            Decimal grantTotal = (line.quantity != null ? line.quantity : 1) * (pug.grantQty != null ? pug.grantQty : 0);
            out.grantDisplay = formatNumber(grantTotal);

            Decimal rate = null;
            String rateUom = 'Unit';
            NegotiatedRateInput nr = negotiatedByLineId.get(line.quoteLineItemId);
            if (nr != null && nr.negotiatedRate != null) {
                rate = nr.negotiatedRate;
            } else {
                FallbackRateInput fr = fallbackByProductId.get(line.product2Id);
                if (fr != null) {
                    rate = fr.rate;
                    rateUom = fr.rateUomName != null ? fr.rateUomName : rateUom;
                }
            }
            out.overageRate = rate != null ? '$' + formatRate(rate) + ' / ' + pug.usageResourceName : 'TBD';

            outputLines.add(out);
        }

        BuildResult result = new BuildResult();
        result.usageLinesJson = JSON.serialize(outputLines);
        return result;
    }

    private static String formatNumber(Decimal d) {
        if (d == null) return '0';
        Long whole = d.longValue();
        String s = String.valueOf(whole);
        String out = '';
        Integer rem = Math.mod(s.length(), 3);
        for (Integer i = 0; i < s.length(); i++) {
            if (i > 0 && Math.mod(i - rem, 3) == 0 && rem > 0) out += ',';
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
}
