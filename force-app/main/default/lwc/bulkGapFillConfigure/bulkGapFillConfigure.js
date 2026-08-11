import { LightningElement, track, wire } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getConfigOptions from "@salesforce/apex/BulkGapFillController.getConfigOptions";
import countFootprintsInScope from "@salesforce/apex/BulkGapFillController.countFootprintsInScope";
import launchRun from "@salesforce/apex/BulkGapFillController.launchRun";

const METHOD_MANUAL = "Manual";

/**
 * Step 1 — build a BulkGapFillRequest, preview its scope, and launch the batch.
 */
export default class BulkGapFillConfigure extends LightningElement {
  @track fillMethodOptions = [];
  @track assetTypeOptions = [];
  @track reportingYearOptions = [];
  @track schemaProblems = [];

  // Request fields, mirroring BulkGapFillRequest.
  reportingYear;
  defaultFillMethod;
  manualDailyRate;
  selectedAssetTypes = [];
  fuelTypesRaw = "";
  isDryRun = false;
  associateOrphans = false;
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
      this.reportingYearOptions = data.reportingYears.map((y) => ({
        label: String(y),
        value: String(y)
      }));
      this.reportingYear = String(data.defaultReportingYear);
      this.batchSize = data.defaultBatchSize;
      this.schemaProblems = data.schemaProblems || [];
    } else if (error) {
      this.toast(
        "Could not load configuration options",
        this.errorMessage(error),
        "error"
      );
    }
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
    this.fuelTypesRaw = event.detail.value;
  }

  handleDryRunChange(event) {
    this.isDryRun = event.detail.checked;
  }

  handleAssociateOrphansChange(event) {
    this.associateOrphans = event.detail.checked;
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
      fuelTypes: this.parsedFuelTypes(),
      isDryRun: this.isDryRun,
      associateOrphans: this.associateOrphans,
      skipAlreadyFilled: this.skipAlreadyFilled,
      batchSize: this.batchSize ? parseInt(this.batchSize, 10) : null
    };
  }

  parsedFuelTypes() {
    return this.fuelTypesRaw
      .split(",")
      .map((s) => s.trim())
      .filter((s) => s.length > 0);
  }

  // ---- Helpers ----------------------------------------------------------

  errorMessage(error) {
    return error?.body?.message || error?.message || "Unknown error";
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
}
