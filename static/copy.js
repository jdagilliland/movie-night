// Reveals and wires up the "copy link" button on the paste view page.
// Without this script, the link itself stays visible and selectable.
document.addEventListener("DOMContentLoaded", () => {
  const button = document.getElementById("copy-link");
  const link = document.getElementById("paste-url");
  if (!button || !link || !navigator.clipboard) return;

  button.hidden = false;
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(link.href);
      button.textContent = "Copied";
    } catch {
      button.textContent = "Copy failed";
    }
    setTimeout(() => {
      button.textContent = "Copy link";
    }, 2000);
  });
});
