# Browser automation roadmap

The initial product supports safe browser-adjacent actions only: open an http/https URL, web search, and focus/open browser via macOS. It does not claim DOM reasoning, login, purchases, message sending, authenticated form completion, or arbitrary site control.

`BrowserAutomationEngine` is intentionally a protocol boundary with availability, attach, execute, cancel, progress, active-tab context, and disposal responsibilities. A future extension, Accessibility implementation, CDP engine, or measured browser harness can sit behind it without changing Realtime, permission policy, the overlay, or tool receipts.
