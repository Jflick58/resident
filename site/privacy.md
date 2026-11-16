---
layout: page
title: Privacy
permalink: /privacy/
description: What Resident keeps on your device and the few things it sends out.
---

Resident is built so that what you say to it stays on your device. This page says exactly what that covers.

## What stays on your device

- **Your chats**, including attached photos and documents.
- **The models** you download, and everything they compute.
- **Memory**: the facts the agent has saved about you. You can read, edit or clear them in Settings, or switch memory off.
- **Skills and agents** you create.
- **What you dictate.** Speech is turned into text by a model on the device.

Resident has no account, no analytics and no server of its own. We cannot see your chats, because they are never sent to us.

## What leaves your device, and when

Only what a tool needs, and only when the agent uses that tool:

- **Web search** sends the search terms to a search service.
- **Reading a page** requests that page's address from the site that hosts it.
- **A connector** (Linear, Notion and others) is sent what the tool call asks for, to the service you connected. Signing in to a connector happens with that service directly; Resident stores the resulting access token in the device's Keychain.
- **Downloading a model** fetches its files from Hugging Face.
- **A server you add**, such as Ollama on your Mac, receives the chat you have with it.

Each of the first three has a switch in every agent. With them off, nothing you write leaves the device.

## Apple Intelligence

If you choose Apple Intelligence as the model, your request is handled by the model built into your device by Apple, under Apple's own terms.

## Changes

If this page changes in a way that matters, the change will be described here with its date.

*Last updated 16 November 2026.*
