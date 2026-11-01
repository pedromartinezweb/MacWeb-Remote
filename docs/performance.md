# Transport latency validation for 1.1.2

## Observed problems and changes

The previous browser client sent one input command per HTTPS request. The server closed every connection after replying, so each command paid for another TCP/TLS handshake. Commands also waited for preceding replies. Browser MJPEG playback could buffer older images on a slow connection.

The server now supports HTTP/1.1 connection reuse, enables TCP_NODELAY and loads its own PKCS#12 identity into process memory rather than importing it into the login keychain. The browser groups ordered input commands, replaces adjacent pending mouse moves and bounds each batch to the server's request-size limit. It downloads and decodes at most one JPEG at a time, requesting the newest available image after completion; unchanged images produce HTTP 204. It does not maintain a playback queue. Capture is capped at 30 fps instead of 15. The capture excludes the remote cursor so the browser's local cursor does not have a delayed embedded duplicate.

## Local HTTPS probe

A Python client performed 40 authenticated `/api/status` requests sequentially on the Mac, using the configured DNS name as TLS SNI and verifying the local CA and hostname. Only TCP resolution was overridden to the configured interface, as in the HTTPS smoke tests. No certificate validation was disabled.

| Measurement | Before | After |
| --- | ---: | ---: |
| Requests completed | 40 | 40 |
| TLS connections | 40 | 1 |
| Total request elapsed time | 746.22 ms | 15.81 ms |
| First request | 16.73 ms | 5.67 ms |
| Median of subsequent requests | 18.70 ms | 0.25 ms |
| Request p95 | 19.20 ms | 0.38 ms |
| Python client CPU, user + system | 0.15 s | 0.06 s |
| Python client maximum resident set | 30,146,560 bytes | 30,883,840 bytes |

The first request includes a new connection; later requests are the warm portion of the sequence. This is a short, single-run diagnostic on the host, not a Wi-Fi round-trip or complete visual-latency measurement. The after probe ran while desktop permissions were pending, so status bodies were smaller (8,520 versus 19,680 bytes over the sequence). The directly verified structural change is reuse of one TLS socket across all 40 requests. Payload sizes alone are not evidence of latency improvement. Server CPU, process-family memory, browser rendering time, end-to-end user latency and agent token usage were not measured in this probe.

## Input scheduling probe

A separate Node VM probe exercised the previous production `command`/`pump` functions and the new production `InputSender`. A stubbed transport acknowledged each request after 20 ms. Forty key commands were enqueued immediately; no events were injected into the desktop.

| Measurement | Before | After |
| --- | ---: | ---: |
| Commands | 40 | 40 |
| Requests | 40 | 2 |
| Elapsed | 809 ms | 41 ms |

This isolates command scheduling with an artificial round-trip delay. It is not a measurement of physical keyboard latency or Wi-Fi performance. Regression tests additionally check button order, stale-move replacement, reconnect cancellation, Unicode request-size bounds and one-frame-at-a-time video decoding.

## Limits

JPEG delivery still needs substantially more bandwidth than an inter-frame video codec. The 30 fps setting is a capture ceiling, not a guaranteed delivered frame rate. Device-specific browser decoding, network congestion and macOS screen-capture permissions still need real-session validation.
