// Behaviour for the paste view page.
document.addEventListener("DOMContentLoaded", () => {
  // Name the tab after a marquee's title. The server sends only "Movie Night"
  // as the title, so link previews, which don't run scripts, can't spoil it.
  const headline = document.querySelector("main.marquee h1");
  if (headline) document.title = "Movie Night · " + headline.textContent;

  // Reveal and wire up the "copy link" button. Without this script, the
  // link itself stays visible and selectable.
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
