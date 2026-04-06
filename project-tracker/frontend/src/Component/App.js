// FFI for App component
export const stopPropagation_ = (event) => () => { event.stopPropagation(); };

// Hash routing
export const getHash_ = () => window.location.hash.slice(1);
export const setHash_ = (hash) => () => { window.location.hash = hash; };

// Subscribe to hashchange events. Calls the callback with the new hash.
// Returns an unsubscribe effect.
export const onHashChange_ = (callback) => () => {
  const handler = () => callback(window.location.hash.slice(1))();
  window.addEventListener("hashchange", handler);
  return () => window.removeEventListener("hashchange", handler);
};

// Subscribe to keydown events. Calls callback with {key, ctrl, meta, shift, target}.
// Returns an unsubscribe effect.
export const onKeyDown_ = (callback) => () => {
  const handler = (e) => {
    const tag = (e.target && e.target.tagName) || "";
    const isInput = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";
    callback({
      key: e.key,
      ctrl: e.ctrlKey,
      meta: e.metaKey,
      shift: e.shiftKey,
      isInput: isInput,
      preventDefault: () => e.preventDefault(),
    })();
  };
  window.addEventListener("keydown", handler);
  return () => window.removeEventListener("keydown", handler);
};

// Focus the search input
export const focusSearch_ = () => {
  const el = document.querySelector(".header-search");
  if (el) el.focus();
};

// Get the number of columns in the project card grid
export const getGridColumns_ = () => {
  const grid = document.querySelector(".project-cards");
  if (!grid) return 1;
  const style = window.getComputedStyle(grid);
  const cols = style.getPropertyValue("grid-template-columns").split(" ").length;
  return cols || 1;
};

// Blur the currently focused element
export const blurActive_ = () => {
  if (document.activeElement) document.activeElement.blur();
};
