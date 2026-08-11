import { LightningElement, track } from "lwc";

const STEP_CONFIGURE = "configure";
const STEP_MONITOR = "monitor";
const STEP_RESULTS = "results";

/**
 * Container for the three-step bulk gap fill experience. Owns the step state and
 * the job id; each step component handles its own data and reports upward.
 */
export default class BulkGapFillWizard extends LightningElement {
  @track currentStep = STEP_CONFIGURE;

  /** Id of the BulkGapFillJob__c produced by the Configure step. */
  jobId;

  /** Request config carried forward so Results can label the run. */
  @track lastRequest;

  get isConfigure() {
    return this.currentStep === STEP_CONFIGURE;
  }

  get isMonitor() {
    return this.currentStep === STEP_MONITOR;
  }

  get isResults() {
    return this.currentStep === STEP_RESULTS;
  }

  /** Fired by bulkGapFillConfigure once the batch has been enqueued. */
  handleLaunched(event) {
    this.jobId = event.detail.jobId;
    this.lastRequest = event.detail.request;
    this.currentStep = STEP_MONITOR;
  }

  /** Fired by bulkGapFillMonitor when the batch reaches a terminal state. */
  handleRunComplete() {
    this.currentStep = STEP_RESULTS;
  }

  /** Lets the user inspect results of a run that is still in flight. */
  handleSkipToResults() {
    this.currentStep = STEP_RESULTS;
  }

  handleStartOver() {
    this.jobId = undefined;
    this.lastRequest = undefined;
    this.currentStep = STEP_CONFIGURE;
  }

  handleBackToMonitor() {
    this.currentStep = STEP_MONITOR;
  }
}
