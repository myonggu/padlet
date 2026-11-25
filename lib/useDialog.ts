"use client";

import { useEffect, useRef, type RefObject } from "react";

const FOCUSABLE =
  'a[href],button:not([disabled]),input:not([disabled]),textarea:not([disabled]),select:not([disabled]),[tabindex]:not([tabindex="-1"])';

/** Escape to close, Tab focus trap, initial focus and focus restore for modal dialogs. */
export function useDialog<T extends HTMLElement>(
  open: boolean,
  onClose: () => void,
  fallbackFocus?: RefObject<HTMLElement | null>,
) {
  const ref = useRef<T>(null);
  const onCloseRef = useRef(onClose);

  useEffect(() => {
    onCloseRef.current = onClose;
  }, [onClose]);

  useEffect(() => {
    if (!open) return;
    const node = ref.current;
    if (!node) return;

    const fallbackNode = fallbackFocus?.current ?? null;
    const active = document.activeElement;
    // Dialog children use data-autofocus (not autoFocus) so the opener is still focused here.
    const opener =
      active instanceof HTMLElement && active !== document.body && !node.contains(active)
        ? active
        : null;
    const previous = opener?.isConnected ? opener : fallbackNode;
    const focusables = () =>
      Array.from(node.querySelectorAll<HTMLElement>(FOCUSABLE)).filter(
        (element) => element.offsetParent !== null || element === document.activeElement,
      );

    if (!node.contains(document.activeElement)) {
      (node.querySelector<HTMLElement>("[data-autofocus]") ?? focusables()[0] ?? node).focus();
    }

    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        onCloseRef.current();
        return;
      }
      if (event.key !== "Tab" || !node) return;
      const items = focusables();
      if (items.length === 0) {
        event.preventDefault();
        node.focus();
        return;
      }
      const first = items[0];
      const last = items[items.length - 1];
      const active = document.activeElement;
      if (event.shiftKey && (active === first || !node.contains(active))) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && (active === last || !node.contains(active))) {
        event.preventDefault();
        first.focus();
      }
    }

    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      const target = previous?.isConnected ? previous : fallbackNode;
      target?.focus();
    };
  }, [open, fallbackFocus]);

  return ref;
}
