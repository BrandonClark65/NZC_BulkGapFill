import { LightningElement, api, track, wire } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getConfigOptions from "@salesforce/apex/BulkGapFillController.getConfigOptions";
import countFootprintsInScope from "@salesforce/apex/BulkGapFillController.countFootprintsInScope";
import launchRun from "@salesforce/apex/BulkGapFillController.launchRun";

const METHOD_MANUAL = "Manual";

/**
 * Step 1 — build a BulkGapFillRequest, preview its scope, and launch the batch.
 */
export default class BulkGapFillConfigure extends LightningElement {
  /**
   * A previously launched request to seed the form from, shaped like the payload
   * `buildRequest()` produces (or the deserialized `BulkGapFillJob__c.FilterCriteria__c`).
   * Set when the user chooses to run a dry run's configuration for real.
   */
  @api prefillRequest;

  @track fillMethodOptions = [];
  @track assetTypeOptions = [];
  @track fuelTypeOptions = [];
  @track reportingYearOptions = [];
  @track schemaProblems = [];

  // Request fields, mirroring BulkGapFillRequest.
  reportingYear;
  defaultFillMethod;
  manualDailyRate;
  selectedAssetTypes = [];
  selectedFuelTypes = [];
  isDryRun = false;
  skipAlreadyFilled = true;
  batchSize;

  scopeCount;
  isCounting = false;
  isLaunching = false;

  @wire(getConfigOptions)
  wiredOptions({ data, error }) {
    if (data) {
      this.fillMethodOptions = data.fillMethods.map((o) => ({
        label: o.label,
        value: o.value
      }));
      this.assetTypeOptions = data.assetTypes.map((o) => ({
        label: o.label,
        value: o.value
      }));
      this.fuelTypeOptions = data.fuelTypes.map((o) => ({
        label: o.label,
        value: o.value
      }));
      this.reportingYearOptions = data.reportingYears.map((y) => ({
        label: String(y),
        value: String(y)
      }));
      this.batchSize = data.defaultBatchSize;
      this.schemaProblems = data.schemaProblems || [];

      if (this.prefillRequest) {
        this.applyPrefill(this.prefillRequest, data);
      } else {
        this.reportingYear = String(data.defaultReportingYear);
      }
    } else if (error) {
      this.toast(
        "Could not load configuration options",
        this.errorMessage(error),
        "error"
      );
    }
  }

  /** Seeds every field from a prior request, forcing dry run off — the whole point
   *  of promoting a preview is to actually create the records this time. */
  applyPrefill(request, data) {
    this.reportingYear =
      request.reportingYear != null
        ? String(request.reportingYear)
        : String(data.defaultReportingYear);
    this.defaultFillMethod = request.defaultFillMethod;
    this.manualDailyRate = request.manualDailyRate;
    this.selectedAssetTypes = request.assetTypes || [];
    this.selectedFuelTypes = request.fuelTypes || [];
    this.skipAlreadyFilled = request.skipAlreadyFilled !== false;
    this.batchSize = request.batchSize || data.defaultBatchSize;
    this.isDryRun = false;
  }

  get hasSchemaProblems() {
    return this.schemaProblems.length > 0;
  }

  get isManualMethod() {
    return this.defaultFillMethod === METHOD_MANUAL;
  }

  get launchDisabled() {
    return this.isLaunching || !this.reportingYear || !this.defaultFillMethod;
  }

  get launchLabel() {
    return this.isDryRun ? "Run Preview" : "Launch Gap Fill";
  }

  get scopeSummary() {
    if (this.scopeCount === undefined) {
      return null;
    }
    return this.scopeCount === 1
      ? "1 carbon footprint record is in scope."
      : `${this.scopeCount} carbon footprint records are in scope.`;
  }

  // ---- Field handlers ---------------------------------------------------

  handleYearChange(event) {
    this.reportingYear = event.detail.value;
    this.scopeCount = undefined;
  }

  handleMethodChange(event) {
    this.defaultFillMethod = event.detail.value;
  }

  handleManualRateChange(event) {
    this.manualDailyRate = event.detail.value;
  }

  handleAssetTypesChange(event) {
    this.selectedAssetTypes = event.detail.value;
    this.scopeCount = undefined;
  }

  handleFuelTypesChange(event) {
    this.selectedFuelTypes = event.detail.value;
  }

  handleDryRunChange(event) {
    this.isDryRun = event.detail.checked;
  }

  handleSkipFilledChange(event) {
    this.skipAlreadyFilled = event.detail.checked;
  }

  handleBatchSizeChange(event) {
    this.batchSize = event.detail.value;
  }

  // ---- Actions ----------------------------------------------------------

  async handleCountScope() {
    this.isCounting = true;
    try {
      this.scopeCount = await countFootprintsInScope({
        requestJson: JSON.stringify(this.buildRequest())
      });
    } catch (error) {
      this.toast(
        "Could not count records in scope",
        this.errorMessage(error),
        "error"
      );
    } finally {
      this.isCounting = false;
    }
  }

  async handleLaunch() {
    this.isLaunching = true;
    const request = this.buildRequest();
    try {
      const jobId = await launchRun({ requestJson: JSON.stringify(request) });
      this.dispatchEvent(
        new CustomEvent("launched", { detail: { jobId, request } })
      );
    } catch (error) {
      this.toast("Could not launch the run", this.errorMessage(error), "error");
    } finally {
      this.isLaunching = false;
    }
  }

  /** Assembles the payload deserialized by BulkGapFillRequest on the Apex side. */
  buildRequest() {
    return {
      reportingYear: this.reportingYear
        ? parseInt(this.reportingYear, 10)
        : null,
      defaultFillMethod: this.defaultFillMethod,
      manualDailyRate:
        this.isManualMethod && this.manualDailyRate
          ? parseFloat(this.manualDailyRate)
          : null,
      methodOverrides: {},
      carbonFootprintIds: [],
      stationaryAssetIds: [],
      assetTypes: this.selectedAssetTypes,
      fuelTypes: this.selectedFuelTypes,
      isDryRun: this.isDryRun,
      skipAlreadyFilled: this.skipAlreadyFilled,
      batchSize: this.batchSize ? parseInt(this.batchSize, 10) : null
    };
  }

  // ---- Helpers ----------------------------------------------------------

  errorMessage(error) {
    return error?.body?.message || error?.message || "Unknown error";
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
}
