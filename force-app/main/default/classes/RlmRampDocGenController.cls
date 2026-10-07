public without sharing class RlmRampDocGenController {

    @AuraEnabled
    public static String generateProposal(String quoteId) {
        RlmRampTokenAssembler assembler = new RlmRampTokenAssembler();
        Map<String, Object> result = (Map<String, Object>) assembler.call('assembleTokenData',
            new Map<String, Object>{ 'quoteId' => quoteId }
        );
        if (result.containsKey('error')) {
            throw new AuraHandledException((String) result.get('error'));
        }
        return (String) result.get('jobId');
    }
}
