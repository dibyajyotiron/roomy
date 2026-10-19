"use strict";

// This educational example contains invented data and never reads the device.
const example = document.querySelector("#sample-review");
if (example) {
  const total = document.querySelector("#sample-total");
  const update = () => {
    const megabytes = [...example.querySelectorAll("input:checked")].reduce(
      (sum, input) => sum + Number(input.value),
      0,
    );
    total.value = `${(megabytes / 1000).toFixed(2)} GB`;
  };
  example.addEventListener("change", update);
  update();
}
