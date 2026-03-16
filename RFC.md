# Demo Tool to transcribe audio with Apple Silicon -- Native MacOS App

The project implements a MacOS native tool to transcribe audio and augment it with AI/LLM capabilities.
The tool relies on availability of Apple Silicon chips M1-M4, though it can fallback onto CPU.
I assume the project to be implemented mainly in Swift, with possible use of python.

In general, it should has UI similar to ChatGPT. 
- On the left panel, hidable, you'll have a list of dialoges. 
- Main section is devoted to the dialogue itself.

In the main section, chat, you should be able to attach audio to transcribe and send a text message to an available LLM.


## Audio

Audio transcription must be done with faster-whisper based on CTranslate2 metal-backend branch specifically from this repo: https://github.com/vsevolod-oparin/CTranslate2/tree/metal-backend

Audio transcription should be controllable in settings. Beam, temperature, online transcription and so on.

- Model shall be downloaded and converted as need. There should be some progress bar showing model download
- Transcription also should be reflected in progress bar.

The tasks in progress bar should be running in the background in non-blocking way. If they fail or app crashed, we should be able to recover them.
Passed, scheduled and in progress task should be visible in some pop-up window/dialogue.
It should be possible to pause/resume/stop/repeat/delete each task separately.

## LLM support

LLM support shall be conducted via API.
I'd like to have support with basic LLMs from Z.ai, Qwen, Deepseek, Anthropic, ChatGPT or similar as long as user has an API key.
There should be a way to choose available models.

## Persistent Storage

Assume to use something like sqlite for dialogues and state. What is more proper.
There also should be some way to store audio files within the app. Find the best way.
For settings, it might be worth to store them in json in ~/.local/bin/<app-name> or similar place.

## Integration with MacOS

It should be possible to open audio file/files with this app, so the user can quickly navigate it into proper existing dialogue or new one. 

## MCP Support [Future options]

Place to investigate, but it's probably worth to include something for image search, map, and even drawing.

## Distribution

I assume to distribute it in unsigned DMG. 
