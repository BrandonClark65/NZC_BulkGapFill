import { createElement } from "lwc";
import BulkGapFillMonitor from "c/bulkGapFillMonitor";
import getJobStatus from "@salesforce/apex/BulkGapFillController.getJobStatus";
import abortRun from "@salesforce/apex/BulkGapFillController.abortRun";

jest.mock(
  "@salesforce/apex/BulkGapFillController.getJobStatus",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/BulkGapFillController.abortRun",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

const JOB_ID = "a01000000000001AAA";

function status({ complete = false, errorCount = 0, errorLog = null } = {}) {
  return {
    job: {
      Id: JOB_ID,
      Name: "BGF-0000001",
      Status__c: complete ? "Completed" : "Running",
      IsDryRun__c: false,
      FootprintsInScope__c: 4,
      FootprintsProcessed__c: complete ? 4 : 2,
      GapsFound__c: 2,
      RecordsCreated__c: errorCount > 0 ? 0 : 2,
      RecordsAssociated__c: 0,
      ErrorCount__c: errorCount,
      ErrorLog__c: errorLog
    },
    percentComplete: complete ? 100 : 50,
    isComplete: complete
  };
}

/** Lets the component's awaited Apex promise and its re-render settle. */
/**
 * Drains the microtask queue so a component's awaited Apex call, and the
 * re-render that follows it, have both happened before assertions run.
 */
function settle() {
  return Promise.resolve().then().then().then().then();
}

describe("c-bulk-gap-fill-monitor", () => {
  let element;

  beforeEach(() => {
    jest.useFakeTimers();
    getJobStatus.mockReset();
    abortRun.mockReset();
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.useRealTimers();
  });

  async function render() {
    element = createElement("c-bulk-gap-fill-monitor", {
      is: BulkGapFillMonitor
    });
    element.jobId = JOB_ID;
    document.body.appendChild(element);
    await settle();
  }

  it("shows the progress the job reports", async () => {
    getJobStatus.mockResolvedValue(status());
    await render();

    expect(getJobStatus).toHaveBeenCalledWith({ jobId: JOB_ID });
    expect(
      element.shadowRoot.querySelector("lightning-progress-bar").value
    ).toBe(50);
    expect(element.shadowRoot.textContent).toContain(
      "2 of 4 footprints processed"
    );
  });

  it("advances to results shortly after a clean finish", async () => {
    getJobStatus.mockResolvedValue(status({ complete: true }));
    const handler = jest.fn();

    await render();
    element.addEventListener("runcomplete", handler);

    expect(handler).not.toHaveBeenCalled(); // Still reading the final counts.
    jest.advanceTimersByTime(1500);
    expect(handler).toHaveBeenCalledTimes(1);
  });

  /**
   * The regression this guards: errors only appear on the final poll, so the old
   * unconditional timer flashed the warning past before it could be read.
   */
  it("holds on the monitor when the run finished with errors", async () => {
    getJobStatus.mockResolvedValue(
      status({
        complete: true,
        errorCount: 2,
        errorLog:
          "Energy use insert failed for footprint a0X: REQUIRED_FIELD_MISSING"
      })
    );
    const handler = jest.fn();

    await render();
    element.addEventListener("runcomplete", handler);

    jest.advanceTimersByTime(60000);
    expect(handler).not.toHaveBeenCalled();
  });

  it("shows the error log inline so the failure can be read without leaving", async () => {
    getJobStatus.mockResolvedValue(
      status({
        complete: true,
        errorCount: 2,
        errorLog: "bad value for restricted picklist field"
      })
    );
    await render();

    const log = element.shadowRoot.querySelector("pre.error-log");
    expect(log).not.toBeNull();
    expect(log.textContent).toContain("restricted picklist");
  });

  it("keeps polling while the run is still going", async () => {
    getJobStatus.mockResolvedValue(status());
    await render();
    expect(getJobStatus).toHaveBeenCalledTimes(1);

    jest.advanceTimersByTime(3000);
    await settle();

    expect(getJobStatus).toHaveBeenCalledTimes(2);
  });

  it("stops polling and says so when contact with the run is lost", async () => {
    getJobStatus.mockRejectedValue({ body: { message: "Record not found" } });
    const toast = jest.fn();

    element = createElement("c-bulk-gap-fill-monitor", {
      is: BulkGapFillMonitor
    });
    element.jobId = JOB_ID;
    element.addEventListener("lightning__showtoast", toast);
    document.body.appendChild(element);
    await settle();

    expect(toast).toHaveBeenCalled();
    expect(toast.mock.calls[0][0].detail.variant).toBe("error");

    jest.advanceTimersByTime(30000);
    await settle();
    expect(getJobStatus).toHaveBeenCalledTimes(1); // No further polls.
  });

  it("aborts the run and moves to results", async () => {
    getJobStatus.mockResolvedValue(status());
    abortRun.mockResolvedValue(undefined);
    await render();

    const skip = jest.fn();
    element.addEventListener("skiptoresults", skip);

    const abortButton = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button")
    ).find((b) => b.label === "Abort Run");
    abortButton.click();
    await settle();

    expect(abortRun).toHaveBeenCalledWith({ jobId: JOB_ID });
    expect(skip).toHaveBeenCalled();
  });

  it("does not poll without a job id", async () => {
    element = createElement("c-bulk-gap-fill-monitor", {
      is: BulkGapFillMonitor
    });
    document.body.appendChild(element);
    await settle();

    expect(getJobStatus).not.toHaveBeenCalled();
  });
});
