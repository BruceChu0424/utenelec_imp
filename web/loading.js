window.addEventListener("flutter-first-frame", () => {
  const loading = document.getElementById("loading");
  if (!loading) return;
  loading.classList.add("done");
  window.setTimeout(() => loading.remove(), 300);
});
