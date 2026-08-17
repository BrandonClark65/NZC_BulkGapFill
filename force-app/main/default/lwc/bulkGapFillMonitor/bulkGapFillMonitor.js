import { LightningElement, api, track } from "lwc";
import getJobStatus from "@salesforce/apex/BulkGapFillController.getJobStatus";
import abortRun from "@salesforce/apex/BulkGapFillController.abortRun";
import { ShowToastEvent } from "lightning/platformShowToastEvent";

const POLL_INTERVAL_MS = 3000;

/**
 * Step 2 — polls the running batch and reports progress until it finishes.
 */
export default class BulkGapFillMonitor extends LightningElement {
  @api jobId;

  @track status;
  isAborting = false;
  pollTimerId;

  connectedCallback() {
    this.poll();
  }

  disconnectedCallback() {
    this.stopPolling();
  }

  get job() {
    return this.status?.job;
  }

  get progressValue() {
    return this.status?.percentComplete ?? 0;
  }

  get progressLabel() {
    const processed = this.job?.FootprintsProcessed__c ?? 0;
    const inScope = this.job?.FootprintsInScope__c;
    return inScope
      ? `${processed} of ${inScope} footprints processed`
      : `${processed} footprints processed`;
  }

  get isComplete() {
    return this.status?.isComplete === true;
  }

  get isRunning() {
    return this.status !== undefined && !this.isComplete;
  }

  get hasErrors() {
    return (this.job?.ErrorCount__c ?? 0) > 0;
  }

  get errorLog() {
    return this.job?.ErrorLog__c;
  }

  get statusVariant() {
    if (this.hasErrors) {
      return "warning";
    }
    return this.isComplete ? "success" : "inverse";
  }

  get isDryRunLabel() {
    return this.job?.IsDryRun__c ? "Preview (dry run)" : "Live run";
  }

  // ---- Polling ----------------------------------------------------------

  async poll() {
    if (!this.jobId) {
      return;
    }
    try {
      this.status = await getJobStatus({ jobId: this.jobId });
    } catch (error) {
      this.stopPolling();
      this.toast(
        "Lost contact with the run",
        this.errorMessage(error),
        "error"
      );
      return;
    }

    if (this.isComplete) {
      this.stopPolling();
      if (this.hasErrors) {
        // Errors only become visible on this final poll, so advancing on a timer
        // would flash them past unread. Hold here and let the user click through.
        return;
      }
      // Give the user a beat to read the final counts before advancing.
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      this.pollTimerId = setTimeout(() => {
        this.dispatchEvent(new CustomEvent("runcomplete"));
      }, 1200);
      return;
    }

    // Polling AsyncApexJob is the only way to track batch progress; the timer is
    // always cleared in stopPolling(), including from disconnectedCallback().
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.pollTimerId = setTimeout(() => this.poll(), POLL_INTERVAL_MS);
  }

  stopPolling() {
    if (this.pollTimerId) {
      clearTimeout(this.pollTimerId);
      this.pollTimerId = undefined;
    }
  }

  // ---- Actions ----------------------------------------------------------

  async handleAbort() {
    this.isAborting = true;
    try {
      await abortRun({ jobId: this.jobId });
      this.stopPolling();
      this.toast(
        "Run aborted",
        "Records already created were not rolled back.",
        "warning"
      );
      this.dispatchEvent(new CustomEvent("skiptoresults"));
    } catch (error) {
      this.toast("Could not abort the run", this.errorMessage(error), "error");
    } finally {
      this.isAborting = false;
    }
  }

  handleViewResults() {
    this.stopPolling();
    this.dispatchEvent(new CustomEvent("skiptoresults"));
  }

  handleStartOver() {
    this.stopPolling();
    this.dispatchEvent(new CustomEvent("startover"));
  }

  // ---- Helpers ----------------------------------------------------------

  errorMessage(error) {
    return error?.body?.message || error?.message || "Unknown error";
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
}
