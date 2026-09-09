import { createElement } from "lwc";
import BulkGapFillConfigure from "c/bulkGapFillConfigure";
import getConfigOptions from "@salesforce/apex/BulkGapFillController.getConfigOptions";
import countFootprintsInScope from "@salesforce/apex/BulkGapFillController.countFootprintsInScope";
import launchRun from "@salesforce/apex/BulkGapFillController.launchRun";

// getConfigOptions is consumed with @wire, so it needs an adapter the test can
// emit through; the other two are called imperatively and are plain mocks.
jest.mock(
  "@salesforce/apex/BulkGapFillController.getConfigOptions",
  () => {
    const { createApexTestWireAdapter } = require("@salesforce/sfdx-lwc-jest");
    return { default: createApexTestWireAdapter(jest.fn()) };
  },
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/BulkGapFillController.countFootprintsInScope",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/BulkGapFillController.launchRun",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

const OPTIONS = {
  fillMethods: [
    {
      label: "Current Year Daily Average",
      value: "Current Year Daily Average"
    },
    { label: "Manual", value: "Manual" }
  ],
  assetTypes: [
    { label: "Office", value: "Office" },
    { label: "Warehouse", value: "Warehouse" }
  ],
  fuelTypes: [
    { label: "Electricity", value: "Electricity" },
    { label: "Natural Gas", value: "NaturalGas" }
  ],
  reportingYears: [2026, 2025, 2024],
  defaultReportingYear: 2025,
  defaultBatchSize: 50,
  schemaProblems: []
};

/**
 * Drains the microtask queue so a component's awaited Apex call, and the
 * re-render that follows it, have both happened before assertions run.
 */
function settle() {
  return Promise.resolve().then().then().then().then();
}

describe("c-bulk-gap-fill-configure", () => {
  let element;

  beforeEach(() => {
    countFootprintsInScope.mockReset();
    launchRun.mockReset();
    element = createElement("c-bulk-gap-fill-configure", {
      is: BulkGapFillConfigure
    });
    document.body.appendChild(element);
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  const all = (tag) => Array.from(element.shadowRoot.querySelectorAll(tag));
  const comboboxes = () => all("lightning-combobox");
  const inputs = () => all("lightning-input");
  const buttons = () => all("lightning-button");
  const buttonNamed = (label) => buttons().find((b) => b.label === label);

  function change(el, detail) {
    el.dispatchEvent(new CustomEvent("change", { detail }));
  }

  async function emitOptions(overrides = {}) {
    getConfigOptions.emit({ ...OPTIONS, ...overrides });
    await settle();
  }

  /** Picks the method, since nothing can launch without one. */
  async function chooseMethod(value = "Current Year Daily Average") {
    change(comboboxes()[1], { value });
    await settle();
  }

  it("seeds the form from the defaults the server supplies", async () => {
    await emitOptions();

    const [year, method] = comboboxes();
    expect(year.value).toBe("2025");
    expect(year.options).toHaveLength(3);
    expect(method.options).toHaveLength(2);
  });

  it("surfaces schema problems so a doomed run is not launched blind", async () => {
    await emitOptions({
      schemaProblems: ["No value in DataGapFillingMethodName matches: Manual"]
    });

    expect(element.shadowRoot.textContent).toContain(
      "No value in DataGapFillingMethodName"
    );
  });

  it("cannot launch until a year and a method are both chosen", async () => {
    await emitOptions();
    expect(buttonNamed("Launch Gap Fill").disabled).toBe(true);

    await chooseMethod();
    expect(buttonNamed("Launch Gap Fill").disabled).toBe(false);
  });

  it("sends the year as a number and the selected fuel types", async () => {
    await emitOptions();
    await chooseMethod();

    const fuelTypesListbox = all("lightning-dual-listbox").find(
      (el) => el.label === "Fuel Types"
    );
    change(fuelTypesListbox, { value: ["Electricity", "NaturalGas"] });
    await settle();

    launchRun.mockResolvedValue("a01000000000001AAA");
    buttonNamed("Launch Gap Fill").click();
    await settle();

    const sent = JSON.parse(launchRun.mock.calls[0][0].requestJson);
    expect(sent.reportingYear).toBe(2025);
    expect(sent.fuelTypes).toEqual(["Electricity", "NaturalGas"]);
    expect(sent.defaultFillMethod).toBe("Current Year Daily Average");
  });

  it("populates the fuel type options from the server picklist", async () => {
    await emitOptions();

    const fuelTypesListbox = all("lightning-dual-listbox").find(
      (el) => el.label === "Fuel Types"
    );
    expect(fuelTypesListbox.options).toEqual(OPTIONS.fuelTypes);
  });

  it("reports the launched job upward so the wizard can advance", async () => {
    await emitOptions();
    await chooseMethod();
    launchRun.mockResolvedValue("a01000000000042AAA");

    const launched = jest.fn();
    element.addEventListener("launched", launched);

    buttonNamed("Launch Gap Fill").click();
    await settle();

    expect(launched).toHaveBeenCalled();
    expect(launched.mock.calls[0][0].detail.jobId).toBe("a01000000000042AAA");
  });

  it("keeps the user on the form and explains when the launch is refused", async () => {
    await emitOptions();
    await chooseMethod();
    launchRun.mockRejectedValue({
      body: { message: "Reporting year required" }
    });

    const launched = jest.fn();
    const toast = jest.fn();
    element.addEventListener("launched", launched);
    element.addEventListener("lightning__showtoast", toast);

    buttonNamed("Launch Gap Fill").click();
    await settle();

    expect(launched).not.toHaveBeenCalled();
    expect(toast.mock.calls[0][0].detail.message).toBe(
      "Reporting year required"
    );
    expect(buttonNamed("Launch Gap Fill").disabled).toBe(false);
  });

  it("counts the records a run would touch, and forgets the count when scope changes", async () => {
    await emitOptions();
    await chooseMethod();
    countFootprintsInScope.mockResolvedValue(1);

    buttonNamed("Check Scope").click();
    await settle();
    expect(element.shadowRoot.textContent).toContain(
      "1 carbon footprint record is in scope."
    );

    // Changing the year invalidates the count rather than leaving a stale one.
    change(comboboxes()[0], { value: "2024" });
    await settle();
    expect(element.shadowRoot.textContent).not.toContain("is in scope.");
  });

  it("pluralises the scope summary", async () => {
    await emitOptions();
    countFootprintsInScope.mockResolvedValue(7);

    buttonNamed("Check Scope").click();
    await settle();

    expect(element.shadowRoot.textContent).toContain(
      "7 carbon footprint records are in scope."
    );
  });

  it("relabels the launch button for a dry run", async () => {
    await emitOptions();
    await chooseMethod();

    const dryRun = inputs().find((i) => i.type === "checkbox");
    change(dryRun, { checked: true });
    await settle();

    expect(buttonNamed("Run Preview")).toBeDefined();
  });

  it("seeds every field from a prefilled request and forces dry run off", async () => {
    element.prefillRequest = {
      reportingYear: 2024,
      defaultFillMethod: "Manual",
      manualDailyRate: 12.5,
      assetTypes: ["Warehouse"],
      fuelTypes: ["NaturalGas"],
      skipAlreadyFilled: false,
      batchSize: 25,
      isDryRun: true
    };
    await emitOptions();

    const [year, method] = comboboxes();
    expect(year.value).toBe("2024");
    expect(method.value).toBe("Manual");

    const checkboxes = inputs().filter((i) => i.type === "checkbox");
    const dryRun = checkboxes[0];
    const skipAlreadyFilled = checkboxes[1];
    expect(dryRun.checked).toBe(false);
    expect(skipAlreadyFilled.checked).toBe(false);

    const assetTypesListbox = all("lightning-dual-listbox").find(
      (el) => el.label === "Asset Types"
    );
    const fuelTypesListbox = all("lightning-dual-listbox").find(
      (el) => el.label === "Fuel Types"
    );
    expect(assetTypesListbox.value).toEqual(["Warehouse"]);
    expect(fuelTypesListbox.value).toEqual(["NaturalGas"]);

    launchRun.mockResolvedValue("a01000000000001AAA");
    buttonNamed("Launch Gap Fill").click();
    await settle();

    const sent = JSON.parse(launchRun.mock.calls[0][0].requestJson);
    expect(sent.isDryRun).toBe(false);
    expect(sent.batchSize).toBe(25);
    expect(sent.manualDailyRate).toBe(12.5);
  });

  it("only sends a manual rate when the method is Manual", async () => {
    await emitOptions();
    await chooseMethod("Manual");

    const rate = inputs().find((i) => i.type === "number");
    change(rate, { value: "12.5" });
    await settle();

    launchRun.mockResolvedValue("a01000000000001AAA");
    buttonNamed("Launch Gap Fill").click();
    await settle();

    const sent = JSON.parse(launchRun.mock.calls[0][0].requestJson);
    expect(sent.manualDailyRate).toBe(12.5);
  });
});
