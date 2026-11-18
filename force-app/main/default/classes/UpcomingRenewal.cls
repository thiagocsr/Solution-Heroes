/**
 * Presentation model for an agreement requiring renewal attention.
 *
 * Flattens relationship fields and pre-computes Days Remaining on the server
 * so the UI does no date arithmetic and the calculation stays consistent with
 * the selection criteria (same reference date, same calendar rules).
 */
public inherited sharing class UpcomingRenewal {
    @AuraEnabled
    public Id agreementId;
    @AuraEnabled
    public String agreementName;
    @AuraEnabled
    public Id accountId;
    @AuraEnabled
    public String accountName;
    @AuraEnabled
    public Date endDate;
    @AuraEnabled
    public Integer daysRemaining;
    @AuraEnabled
    public Decimal agreementValue;
    @AuraEnabled
    public Id accountManagerId;
    @AuraEnabled
    public String accountManagerName;
    @AuraEnabled
    public String renewalStatus;
    @AuraEnabled
    public Boolean renewalStarted;

    public UpcomingRenewal(Service_Agreement__c agreement, Date today) {
        this.agreementId = agreement.Id;
        this.agreementName = agreement.Name;
        this.accountId = agreement.Account__c;
        this.accountName = agreement.Account__r?.Name;
        this.endDate = agreement.End_Date__c;
        // Calendar days between the two dates; Date arithmetic is leap-year aware.
        this.daysRemaining = today.daysBetween(agreement.End_Date__c);
        this.agreementValue = agreement.Agreement_Value__c;
        this.accountManagerId = agreement.Account_Manager__c;
        this.accountManagerName = agreement.Account_Manager__r?.Name;
        this.renewalStatus = agreement.Renewal_Status__c;
        this.renewalStarted = agreement.Renewal_Status__c == RenewalService.RENEWAL_STATUS_IN_PROGRESS;
    }
}
