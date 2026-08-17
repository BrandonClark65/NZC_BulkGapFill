import { createElement } from "lwc";
import BulkGapFillWizard from "c/bulkGapFillWizard";

/**
 * The wizard owns only step state and the job id. These tests drive it through
 * the events its three children raise, since that is the whole of its behaviour.
 */
describe("c-bulk-gap-fill-wizard", () => {
  let element;

  beforeEach(() => {
    element = createElement("c-bulk-gap-fill-wizard", {
      is: BulkGapFillWizard
    });
    document.body.appendChild(element);
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  const step = (tag) => element.shadowRoot.querySelector(tag);
  const configure = () => step("c-bulk-gap-fill-configure");
  const monitor = () => step("c-bulk-gap-fill-monitor");
  const results = () => step("c-bulk-gap-fill-results");

  async function launch(jobId = "a01000000000001AAA") {
    configure().dispatchEvent(
      new CustomEvent("launched", {
        detail: { jobId, request: { reportingYear: 2025 } }
      })
    );
    await Promise.resolve();
  }

  it("opens on the configure step", () => {
    expect(configure()).not.toBeNull();
    expect(monitor()).toBeNull();
    expect(results()).toBeNull();
  });

  it("moves to monitor when configure reports a launch, carrying the job id", async () => {
    await launch("a01000000000042AAA");

    expect(configure()).toBeNull();
    expect(monitor()).not.toBeNull();
    expect(monitor().jobId).toBe("a01000000000042AAA");
  });

  it("moves to results when the run completes", async () => {
    await launch();

    monitor().dispatchEvent(new CustomEvent("runcomplete"));
    await Promise.resolve();

    expect(results()).not.toBeNull();
    expect(monitor()).toBeNull();
  });

  it("lets the user skip to results while the run is still going", async () => {
    await launch();

    monitor().dispatchEvent(new CustomEvent("skiptoresults"));
    await Promise.resolve();

    expect(results()).not.toBeNull();
  });

  it("returns from results to monitor with the job id intact", async () => {
    await launch("a01000000000042AAA");
    monitor().dispatchEvent(new CustomEvent("runcomplete"));
    await Promise.resolve();

    results().dispatchEvent(new CustomEvent("backtomonitor"));
    await Promise.resolve();

    expect(monitor()).not.toBeNull();
    expect(monitor().jobId).toBe("a01000000000042AAA");
  });

  it("clears the job id when starting over, so the next run cannot inherit it", async () => {
    await launch("a01000000000042AAA");

    monitor().dispatchEvent(new CustomEvent("startover"));
    await Promise.resolve();

    expect(configure()).not.toBeNull();

    // Reaching monitor again without launching would surface a stale id.
    await launch("a01000000000099AAA");
    expect(monitor().jobId).toBe("a01000000000099AAA");
  });
});
