import { LightningElement, api, track } from "lwc";
import getJobStatus from "@salesforce/apex/BulkGapFillController.getJobStatus";
import getJobDetails from "@salesforce/apex/BulkGapFillController.getJobDetails";
import { ShowToastEvent } from "lightning/platformShowToastEvent";

const PAGE_SIZE = 200;

const COLUMNS = [
  { label: "Asset", fieldName: "StationaryAssetName__c", wrapText: true },
  { label: "Fuel Type", fieldName: "FuelType__c" },
  { label: "Method", fieldName: "FillMethodUsed__c" },
  {
    label: "Gaps",
    fieldName: "GapsFound__c",
    type: "number",
    cellAttributes: { alignment: "right" }
  },
  {
    label: "Gap Days",
    fieldName: "GapDays__c",
    type: "number",
    cellAttributes: { alignment: "right" }
  },
  {
    label: "Records",
    fieldName: "RecordsCreated__c",
    type: "number",
    cellAttributes: { alignment: "right" }
  },
  {
    label: "Energy Filled",
    fieldName: "EnergyFilled__c",
    type: "number",
    cellAttributes: { alignment: "right" }
  },
  { label: "Unit", fieldName: "EnergyFilledUnit__c" },
  { label: "Status", fieldName: "Status__c" },
  { label: "Message", fieldName: "ErrorMessage__c", wrapText: true }
];

const STATUS_FILTERS = [
  { label: "All", value: "" },
  { label: "Filled", value: "Filled" },
  { label: "Preview (Dry Run)", value: "Preview" },
  { label: "No Gaps", value: "No Gaps" },
  { label: "Skipped", value: "Skipped" },
  { label: "Error", value: "Error" }
];

/**
 * Step 3 — per-asset breakdown of a completed (or in-flight) run, with CSV export.
 */
export default class BulkGapFillResults extends LightningElement {
  @api jobId;

  @track details = [];
  @track job;
  columns = COLUMNS;
  statusFilterOptions = STATUS_FILTERS;
  statusFilter = "";
  isLoading = false;
  hasMore = false;

  connectedCallback() {
    this.loadAll();
  }

  get hasDetails() {
    return this.details.length > 0;
  }

  get summaryLabel() {
    if (!this.job) {
      return "";
    }
    const mode = this.job.IsDryRun__c ? "Preview" : "Run";
    return `${mode} ${this.job.Name} — ${this.job.Status__c}`;
  }

  get exportDisabled() {
    return !this.hasDetails;
  }

  async loadAll() {
    this.isLoading = true;
    try {
      const [status, details] = await Promise.all([
        getJobStatus({ jobId: this.jobId }),
        getJobDetails({
          jobId: this.jobId,
          statusFilter: this.statusFilter || null,
          pageSize: PAGE_SIZE,
          pageOffset: 0
        })
      ]);
      this.job = status.job;
      this.details = details;
      this.hasMore = details.length === PAGE_SIZE;
    } catch (error) {
      this.toast("Could not load results", this.errorMessage(error), "error");
    } finally {
      this.isLoading = false;
    }
  }

  async handleLoadMore() {
    this.isLoading = true;
    try {
      const next = await getJobDetails({
        jobId: this.jobId,
        statusFilter: this.statusFilter || null,
        pageSize: PAGE_SIZE,
        pageOffset: this.details.length
      });
      this.details = [...this.details, ...next];
      this.hasMore = next.length === PAGE_SIZE;
    } catch (error) {
      this.toast(
        "Could not load more results",
        this.errorMessage(error),
        "error"
      );
    } finally {
      this.isLoading = false;
    }
  }

  handleFilterChange(event) {
    this.statusFilter = event.detail.value;
    this.loadAll();
  }

  handleRefresh() {
    this.loadAll();
  }

  handleStartOver() {
    this.dispatchEvent(new CustomEvent("startover"));
  }

  handleBackToMonitor() {
    this.dispatchEvent(new CustomEvent("backtomonitor"));
  }

  /**
   * Exports the rows currently loaded. Note this is the loaded page set, not the
   * full server-side result, so paging through first gives a complete export.
   */
  handleExportCsv() {
    const header = this.columns.map((c) => c.label);
    const rows = this.details.map((d) =>
      this.columns.map((c) => this.csvCell(d[c.fieldName]))
    );
    const csv = [header, ...rows].map((row) => row.join(",")).join("\n");

    const link = document.createElement("a");
    link.href = `data:text/csv;charset=utf-8,${encodeURIComponent(csv)}`;
    link.download = `bulk-gap-fill-${this.job?.Name || this.jobId}.csv`;
    link.click();
  }

  csvCell(value) {
    if (value === undefined || value === null) {
      return "";
    }
    const text = String(value);
    // Quote anything that would otherwise break the row, doubling inner quotes.
    return /[",\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
  }

  errorMessage(error) {
    return error?.body?.message || error?.message || "Unknown error";
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
}
