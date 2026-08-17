import { createElement } from "lwc";
import BulkGapFillResults from "c/bulkGapFillResults";
import getJobStatus from "@salesforce/apex/BulkGapFillController.getJobStatus";
import getJobDetails from "@salesforce/apex/BulkGapFillController.getJobDetails";

jest.mock(
  "@salesforce/apex/BulkGapFillController.getJobStatus",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/BulkGapFillController.getJobDetails",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

const JOB_ID = "a01000000000001AAA";

const JOB = {
  job: {
    Id: JOB_ID,
    Name: "BGF-0000001",
    Status__c: "Completed",
    IsDryRun__c: false
  }
};

function detail(overrides = {}) {
  return {
    Id: "a02000000000001AAA",
    StationaryAssetName__c: "HQ",
    FuelType__c: "Electricity",
    FillMethodUsed__c: "Current Year Daily Average",
    GapsFound__c: 1,
    GapDays__c: 184,
    RecordsCreated__c: 1,
    EnergyFilled__c: 100800,
    EnergyFilledUnit__c: "kWh",
    Status__c: "Filled",
    ErrorMessage__c: null,
    ...overrides
  };
}

/**
 * Drains the microtask queue so a component's awaited Apex call, and the
 * re-render that follows it, have both happened before assertions run.
 */
function settle() {
  return Promise.resolve().then().then().then().then();
}

describe("c-bulk-gap-fill-results", () => {
  let element;

  beforeEach(() => {
    getJobStatus.mockReset();
    getJobDetails.mockReset();
    getJobStatus.mockResolvedValue(JOB);
    getJobDetails.mockResolvedValue([detail()]);
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.restoreAllMocks();
  });

  async function render() {
    element = createElement("c-bulk-gap-fill-results", {
      is: BulkGapFillResults
    });
    element.jobId = JOB_ID;
    document.body.appendChild(element);
    await settle();
  }

  const datatable = () =>
    element.shadowRoot.querySelector("lightning-datatable");
  const buttonNamed = (label) =>
    Array.from(element.shadowRoot.querySelectorAll("lightning-button")).find(
      (b) => b.label === label
    );

  /** Captures the anchor handleExportCsv builds, without letting it navigate. */
  function captureDownload() {
    const anchor = { href: "", download: "", click: jest.fn() };
    jest.spyOn(document, "createElement").mockReturnValue(anchor);
    return anchor;
  }

  function csvFrom(anchor) {
    return decodeURIComponent(
      anchor.href.replace("data:text/csv;charset=utf-8,", "")
    );
  }

  it("loads the run and its per-asset rows", async () => {
    await render();

    expect(getJobStatus).toHaveBeenCalledWith({ jobId: JOB_ID });
    expect(getJobDetails).toHaveBeenCalledWith({
      jobId: JOB_ID,
      statusFilter: null,
      pageSize: 200,
      pageOffset: 0
    });
    expect(datatable().data).toHaveLength(1);
    expect(element.shadowRoot.textContent).toContain("BGF-0000001");
  });

  it("reloads with a status filter when one is picked", async () => {
    await render();
    getJobDetails.mockResolvedValue([detail({ Status__c: "Error" })]);

    element.shadowRoot
      .querySelector("lightning-combobox")
      .dispatchEvent(new CustomEvent("change", { detail: { value: "Error" } }));
    await settle();

    expect(getJobDetails).toHaveBeenLastCalledWith({
      jobId: JOB_ID,
      statusFilter: "Error",
      pageSize: 200,
      pageOffset: 0
    });
  });

  it("appends the next page rather than replacing what is shown", async () => {
    getJobDetails.mockResolvedValue(
      Array.from({ length: 200 }, (unused, i) =>
        detail({ Id: `a020000000000${i}AAA` })
      )
    );
    await render();
    expect(datatable().data).toHaveLength(200);

    getJobDetails.mockResolvedValue([detail({ Id: "a02000000000999AAA" })]);
    buttonNamed("Load More").click();
    await settle();

    expect(datatable().data).toHaveLength(201);
    expect(getJobDetails).toHaveBeenLastCalledWith(
      expect.objectContaining({ pageOffset: 200 })
    );
  });

  it("exports the loaded rows as CSV under the job name", async () => {
    await render();
    const anchor = captureDownload();

    buttonNamed("Export CSV").click();

    const csv = csvFrom(anchor);
    const [header, row] = csv.split("\n");
    expect(header).toContain("Asset");
    expect(header).toContain("Status");
    expect(row).toContain("HQ");
    expect(row).toContain("Filled");
    expect(anchor.download).toBe("bulk-gap-fill-BGF-0000001.csv");
    expect(anchor.click).toHaveBeenCalled();
  });

  /**
   * Error messages routinely carry commas, and a bare comma would silently shift
   * every later column in the exported row.
   */
  it("quotes CSV values containing commas, quotes, or newlines", async () => {
    getJobDetails.mockResolvedValue([
      detail({
        Status__c: "Error",
        StationaryAssetName__c: 'The "Big" Warehouse',
        ErrorMessage__c:
          "bad value for restricted picklist field: Manual, retry"
      })
    ]);
    await render();
    const anchor = captureDownload();

    buttonNamed("Export CSV").click();

    const row = csvFrom(anchor).split("\n")[1];
    expect(row).toContain('"The ""Big"" Warehouse"');
    expect(row).toContain(
      '"bad value for restricted picklist field: Manual, retry"'
    );
  });

  it("writes empty cells for missing values rather than the word null", async () => {
    getJobDetails.mockResolvedValue([
      detail({ ErrorMessage__c: null, EnergyFilledUnit__c: undefined })
    ]);
    await render();
    const anchor = captureDownload();

    buttonNamed("Export CSV").click();

    const row = csvFrom(anchor).split("\n")[1];
    expect(row).not.toContain("null");
    expect(row).not.toContain("undefined");
  });

  it("disables export when there is nothing to export", async () => {
    getJobDetails.mockResolvedValue([]);
    await render();

    expect(buttonNamed("Export CSV").disabled).toBe(true);
  });

  it("raises navigation events for the wizard to act on", async () => {
    await render();
    const startOver = jest.fn();
    const back = jest.fn();
    element.addEventListener("startover", startOver);
    element.addEventListener("backtomonitor", back);

    buttonNamed("New Run").click();
    buttonNamed("Back to Monitor").click();

    expect(startOver).toHaveBeenCalled();
    expect(back).toHaveBeenCalled();
  });

  it("explains when the results cannot be loaded", async () => {
    getJobDetails.mockRejectedValue({ body: { message: "Job not found" } });
    const toast = jest.fn();

    element = createElement("c-bulk-gap-fill-results", {
      is: BulkGapFillResults
    });
    element.jobId = JOB_ID;
    element.addEventListener("lightning__showtoast", toast);
    document.body.appendChild(element);
    await settle();

    expect(toast.mock.calls[0][0].detail.message).toBe("Job not found");
  });
});
