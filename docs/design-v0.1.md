# Morning Agent — Design Doc v0.1

*Proactive voice check-in agent: standalone hardware for at-home sessions, app for the rest of the day.*
*Status: filed for later. Job search ships first. Drafted 2026-09-06.*

---

## One-liner

A structured agent that starts a short verbal conversation with me every morning (and optionally at night) — briefs my day, asks what actually happened yesterday, and asks one or two questions that make it smarter — with memory that persists and compounds, running long-term on a dedicated home device that speaks first without me opening an app.

## Why this exists

A useful personal assistant needs three things current AI assistants only partially have, and the morning conversation patches all three at once:

**State.** The agent's model of my life (cars and where they live, gym, standing preferences, active projects) drifts stale. The fix is a structured store where every fact carries a last-confirmed timestamp, and the agent re-verifies the oldest load-bearing facts conversationally ("still lifting 5 days a week?").

**Policy.** What lets a real assistant act without constant check-ins isn't intelligence — it's a calibrated mandate. Standing rules ("always free to move my solo calendar blocks; never touch events with attendees") get learned one question at a time: whenever the agent acted or held back, it can ask "should I have just done that?" and promote the answer to a rule.

**Feedback.** The agent schedules things but never observes outcomes, so its priors can't calibrate. The morning session converts this into a self-report loop at near-zero cost: diff yesterday's plan against what actually happened, ask about the gaps, update. After a few weeks it knows my wrenching time estimates run 2x and my optional evening study blocks land ~30% of the time, and plans around reality instead of intention.

The key insight: I'm standing there making coffee anyway. The marginal cost of the observation channel is zero if the session is short enough.

## Design principles

**The question budget is the whole game.** My patience at 7am is the scarce resource. Six questions a morning kills the ritual in two weeks; the right one or two compound indefinitely. The agent maintains a persistent queue of candidate questions (stale facts, yesterday's gaps, pending policy confirmations) ranked by expected value of information — how much would this answer change future behavior — hard-capped at 1–2 per session. Everything else defers. Total session under five minutes.

**Tuning happens in-band, not in config.** "One question today, not three," said out loud, is itself a policy update — the tuning surface is the conversation. But explicit tuning only covers direction; drift arrives as silence. The dangerous failure mode isn't me saying "too much," it's me silently skipping mornings. So the agent also treats implicit signals — session length, clipped answers, skipped days — as throttle inputs and self-adjusts without being told.

**Consent hardware.** A proactive device that speaks first needs a physical opt-out: a button that means "don't start talking tomorrow." One flag toggle in software, but load-bearing for trust in the product.

**Memory is a schema, not a transcript.** Three tables, not an append-only log: **facts** (entity, attribute, value, last-confirmed timestamp), **outcomes** (planned vs. actual, daily), **rules** (standing mandates and preferences). Weekly consolidation pass so it never becomes a junk drawer.

## Session protocol (morning)

1. Brief the day: calendar, weather, anything time-critical.
2. Diff yesterday: what was planned vs. what I report happened; log to outcomes.
3. Ask the top 1–2 questions off the scored queue (stale fact verification, gap follow-up, or mandate confirmation).
4. Accept in-band tuning commands as standing rule changes.
5. Done in under five minutes.

Night session (later, optional): tomorrow preview + same-day outcome capture while memory is fresh. Includes the skip-tomorrow button press as a valid outcome.

## Architecture ladder

**Level 0 — validate the ritual (now, zero build).** Claude app voice mode + native claude.ai memory. Phone automation (iOS Shortcut / Android routine) tied to alarm dismissal launches straight into voice mode. Still requires saying "morning" to kick off, but friction is near zero. This exists to test the only real risk: whether the habit sticks.

**Level 1 — own the memory.** Move the store into structured external storage the agent reads at session start and writes at session end. Notion (three databases matching the schema above) or SQLite. Required anyway for Level 2, since the API doesn't carry claude.ai's native memory.

**Level 2 — the device.** Standalone hardware that wakes on schedule and speaks first. Candidates: ESP32-S3 (the S3-BOX dev kits are built for exactly this: mic array, speaker, display) or Pi Zero 2 W + ReSpeaker hat. Pipeline: scheduled wake → streamed STT → Claude API with memory store injected into context → streamed TTS. Physical skip-tomorrow button. Companion use of the regular app during the day; device owns the home sessions.

**The critical engineering problem is latency, not features.** A laggy voice loop feels terrible at 7am. Stream the entire pipeline end to end rather than request-response; set a wake-to-first-word budget (target: sub-second) and spend most of the build effort there.

## Metrics to instrument from day one

Adherence (sessions per week), session duration, question count per session, wake-to-first-word latency (Level 2), plan-vs-actual accuracy trend, rules accumulated over time. These are both the tuning signals and the proof-of-daily-use story.

## Resume framing

This fuses the two strongest portfolio threads — hardware (ESP32 solar rig, vibration monitor, bus display) and agents (`/standup` work agent, OpenClaw agent) — into one artifact: *proactive voice agent with persistent structured memory, on self-built hardware, used every morning for N days, with the usage data to prove it.* Lead the repo with the agent loop (memory architecture, EV-scored question scheduler, staleness-driven verification) and the latency engineering; the hardware is the deployment target and the hook, not the headline. Strong signal for AI-product startups (EliseAI/Basis-shaped companies); roughly neutral for quant shops. Heavy overlap with the Lifesergic thesis — this is a life-OS feature being dogfooded daily.

## Sequencing and guardrails

Job search is the priority through end of October; this project is the single most seductive form of productive procrastination for my profile and is treated accordingly. Permitted now: Level 0 trial (validates the ritual, accrues the usage story), this design doc, and scope-boxed evening prototyping. The full Level 2 build is either the post-signing celebration project or a Lifesergic flagship demo — not a September activity.

**Tonight's prototype box (long weekend allowance, ~2 hours hard cap):** pick ONE — (a) set up the alarm-dismissal phone automation and run a dry morning session, or (b) latency spike: a throwaway Python voice loop on the laptop (streaming STT → Claude API → streaming TTS) purely to measure wake-to-first-word and learn where the milliseconds go. Both produce learning; neither opens the hardware drawer.

## Open questions

Name (working title "Morning Agent" is a placeholder). Night session: valuable or scope creep? Wake trigger for Level 2: fixed schedule, alarm integration, or presence detection. Privacy stance: scheduled-wake only vs. any always-listening capability (leaning hard toward scheduled-only). Store: Notion (visible, editable, already home to everything) vs. SQLite (faster, private, more robust for a device). STT/TTS provider choice and on-device vs. cloud split.
