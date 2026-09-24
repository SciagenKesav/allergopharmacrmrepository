trigger SampleAttemptEventTrigger on Sample_Attempt__e (after insert) {
    SampleAttemptLogService.log(Trigger.new);
}