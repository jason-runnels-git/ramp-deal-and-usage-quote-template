import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import generateProposal from '@salesforce/apex/RlmRampDocGenController.generateProposal';

export default class RlmRampDocGen extends LightningElement {
    @api recordId;
    isGenerating = false;
    successMessage = '';
    errorMessage = '';

    handleGenerate() {
        this.isGenerating = true;
        this.successMessage = '';
        this.errorMessage = '';

        generateProposal({ quoteId: this.recordId })
            .then(() => {
                this.isGenerating = false;
                this.successMessage = 'Proposal generation started. Check Files on this record in a few moments.';
                setTimeout(() => {
                    this.dispatchEvent(new CloseActionScreenEvent());
                }, 2500);
            })
            .catch(error => {
                this.isGenerating = false;
                this.errorMessage = 'Generation failed: ' + (error.body?.message || error.message || 'Unknown error');
            });
    }
}
