"use strict";

const cards = [...document.querySelectorAll(".product-card")];
const filters = [...document.querySelectorAll("[data-filter]")];
const search = document.querySelector("#search");
const languageButton = document.querySelector("#language");
let category = "all";
let language = "zh";

function filterProducts() {
  const term = search.value.trim().toLocaleLowerCase();
  let count = 0;
  for (const card of cards) {
    // Both official subtitles stay searchable in either display language.
    const subtitle = card.querySelector(".product-subtitle");
    const content = `${card.textContent} ${subtitle.dataset.zh} ${subtitle.dataset.en}`;
    const matches = (category === "all" || card.dataset.category === category)
      && content.toLocaleLowerCase().includes(term);
    card.hidden = !matches;
    if (matches) count += 1;
  }
  document.querySelector("#empty-state").hidden = count > 0;
  document.querySelector("#result-count").textContent = language === "zh"
    ? `显示 ${count} 个产品` : `${count} products shown`;
}

for (const button of filters) {
  button.addEventListener("click", () => {
    category = button.dataset.filter;
    for (const filter of filters) {
      filter.setAttribute("aria-pressed", String(filter === button));
    }
    filterProducts();
  });
}
search.addEventListener("input", filterProducts);

languageButton.addEventListener("click", () => {
  language = language === "zh" ? "en" : "zh";
  document.documentElement.lang = language === "zh" ? "zh-CN" : "en";
  for (const element of document.querySelectorAll("[data-zh][data-en]")) {
    element.textContent = element.dataset[language];
  }
  languageButton.textContent = language === "zh" ? "EN" : "中文";
  languageButton.setAttribute("aria-label", language === "zh" ? "Switch to English" : "切换为中文");
  search.placeholder = language === "zh" ? "搜索产品…" : "Search products…";
  search.setAttribute("aria-label", language === "zh" ? "搜索产品" : "Search products");
  document.querySelector("nav").setAttribute("aria-label", language === "zh" ? "主导航" : "Main navigation");
  document.querySelector(".filters")?.setAttribute("aria-label", language === "zh" ? "产品分类" : "Product categories");
  for (const wordmark of document.querySelectorAll(".wordmark")) {
    wordmark.setAttribute("aria-label", language === "zh" ? "Colvenna 科维纳首页" : "Colvenna home");
  }
  document.title = language === "zh"
    ? "Colvenna 科维纳 — 列与流 · 公开产品"
    : "Colvenna — Columns & flow · Public products";
  filterProducts();
});

document.querySelector(".catalog-tools").hidden = false;
languageButton.hidden = false;
filterProducts();
