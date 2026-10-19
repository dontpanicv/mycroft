// One thread: the transcript as a console (user turns as bordered blocks, prose, numbered tool rows) and the
// glass composer with voice, send, steer and stop. Voice is the app's on-device listener (the `listen` events): hold
// the mic to talk and let go to send, or tap it and pause; "Read aloud" in the header reads answers and keeps
// listening.

import { html, useEffect, useLayoutEffect, useRef, useState } from '/lib/preact.js'
import { useData, useCall, useUI, useNavigation, Icon, Label, Tag, Markdown, Spinner, pad, duration, summarize, haptic } from '../lib.js'

export function Thread({ id }) {
	const call = useCall()
	const { back } = useNavigation()
	const view = useData((d) => d.views[id])
	const meta = useData((d) => d.state?.threads?.find((t) => t.id === id))
	const [error, setError] = useState(null)
	const scroller = useRef(null)
	const pinned = useRef(true)

	useEffect(() => {
		call('thread.open', { id }).catch((e) => setError(e.message))
		return () => {
			call('thread.close', { id }).catch(() => {})
			call('listen.close').catch(() => {})
		}
	}, [id])

	// Follow the bottom while the user is there.
	const onScroll = () => {
		const el = scroller.current
		pinned.current = el.scrollHeight - el.scrollTop - el.clientHeight < 120
	}
	useLayoutEffect(() => {
		const el = scroller.current
		if (el && pinned.current) el.scrollTop = el.scrollHeight
	})
	// The keyboard shrinks the screen: stay at the bottom.
	useEffect(() => {
		const follow = () => {
			const el = scroller.current
			if (el && pinned.current) el.scrollTop = el.scrollHeight
		}
		addEventListener('resize', follow)
		return () => removeEventListener('resize', follow)
	}, [])

	const busy = view?.busy ?? false
	const showProgress = useLinger(busy, 600)
	return html`
		<main class="screen thread">
			<header class="bar glass-bar">
				<button class="icon-button glass" aria-label="Back" onClick=${back}><${Icon} name="back" /></button>
				<div class="bar-title">
					<span class="title mono">${meta?.title ?? 'Thread'}</span>
					<span class=${`label tiny ${busy ? 'soft' : 'faint'}`} id="status">${busy ? 'Running' : 'Idle'}</span>
				</div>
				<${ReadAloud} id=${id} onError=${setError} />
				${showProgress && html`<div class="progress"></div>`}
			</header>
			<div class="scroll transcript" ref=${scroller} onScroll=${onScroll}>
				${view ? html`<${Transcript} view=${view} />` : html`<div class="center"><${Spinner} /></div>`}
				${(error || view?.error) && html`<p class="card danger mono small">${error || view.error}</p>`}
				<div class="composer-space"></div>
			</div>
			<${Composer} id=${id} busy=${busy} model=${view?.model} onError=${setError} />
		</main>
	`
}

/** `value`, but a `true` stays for `ms` after it turns false, so a run that pauses for a moment doesn't blink. */
function useLinger(value, ms) {
	const [shown, setShown] = useState(value)
	useEffect(() => {
		if (value) return setShown(true)
		const timer = setTimeout(() => setShown(false), ms)
		return () => clearTimeout(timer)
	}, [value])
	return shown
}

// MARK: Transcript

function Transcript({ view }) {
	const entries = view.entries ?? []
	const results = {}
	for (const entry of entries) {
		const message = entry.model?.[0]
		if (message?.role === 'toolResult') results[message.toolCallId] = message
	}
	const numbers = {}
	const streaming = view.live?.generation?.message
	for (const message of [...entries.map((e) => e.model?.[0]), streaming]) {
		if (message?.role !== 'assistant') continue
		for (const block of message.content ?? []) {
			if (block.type === 'toolCall' && !(block.id in numbers)) numbers[block.id] = Object.keys(numbers).length + 1
		}
	}
	const liveTools = view.live?.tools ?? []
	const last = [...entries].reverse().find((e) => e.model?.[0]?.role === 'assistant')?.model?.[0]

	return html`
		${entries.map((entry) => {
			const message = entry.model?.[0]
			if (message?.role === 'user') return html`<${UserTurn} key=${entry.id} message=${message} />`
			if (message?.role === 'assistant')
				return html`<${AssistantTurn} key=${entry.id} message=${message} results=${results} numbers=${numbers} live=${liveTools} />`
			return null
		})}
		${streaming
			? html`<${AssistantTurn} message=${streaming} results=${results} numbers=${numbers} live=${liveTools} />`
			: view.busy && html`<div class="row gap soft working"><${Spinner} /><${Label} tone="soft">${liveTools.length ? 'Working' : 'Thinking'}<//></div>`}
		${!view.busy && last?.errorMessage && html`<p class="card danger mono small">${last.errorMessage}</p>`}
		${view.queued > 0 && html`<p class="faint mono small">${view.queued} message${view.queued > 1 ? 's' : ''} queued</p>`}
	`
}

function textOf(message) {
	if (typeof message.content === 'string') return message.content
	return (message.content ?? []).filter((b) => b.type === 'text').map((b) => b.text).join('\n')
}

function UserTurn({ message }) {
	return html`<div class="card user-turn">
		<${Label} tone="faint" size=${9.5}>You<//>
		<p class="user-text">${textOf(message)}</p>
	</div>`
}

function AssistantTurn({ message, results, numbers, live }) {
	return html`<div class="assistant-turn">
		${(message.content ?? []).map((block, i) => {
			if (block.type === 'text' && block.text) return html`<${Markdown} key=${i} text=${block.text} />`
			if (block.type === 'thinking' && block.thinking) return html`<${Thinking} key=${i} text=${block.thinking} />`
			if (block.type === 'toolCall')
				return html`<${ToolRow} key=${block.id} index=${numbers[block.id] ?? 0} call=${block} result=${results[block.id]}
					live=${live.find((slot) => slot.callId === block.id)} />`
			return null
		})}
	</div>`
}

function Thinking({ text }) {
	const [open, setOpen] = useState(false)
	return html`<div class="thinking">
		<button class="disclosure" onClick=${() => setOpen(!open)}><${Icon} name=${open ? 'down' : 'chevron'} size=${12} /><${Label} tone="faint" size=${9.5}>Thinking<//></button>
		${open && html`<p class="muted small">${text}</p>`}
	</div>`
}

/** `01 hands_exec  uname -a   ✓ 0.4s` — one tool call, expandable to its output. */
function ToolRow({ index, call, result, live }) {
	const [open, setOpen] = useState(false)
	const output = result ? result.content ?? [] : live?.output ? [{ type: 'text', text: live.output }] : []
	const text = output.filter((b) => b.type === 'text').map((b) => b.text).join('\n')
	const images = output.filter((b) => b.type === 'image')
	return html`<div class="tool">
		<button class="tool-head" onClick=${() => setOpen(!open)} aria-expanded=${open}>
			<span class="index">${pad(index)}</span>
			<span class="tool-name">${call.name}</span>
			<span class="tool-arg">${summarize(call.arguments)}</span>
			${result
				? html`<span class=${`tool-status ${result.isError ? 'danger' : 'success'}`}>
						<${Icon} name=${result.isError ? 'close' : 'check'} size=${13} stroke=${2.4} />${duration(result.durationMs)}</span>`
				: html`<${Spinner} />`}
		</button>
		${open && (text || images.length)
			? html`<div class="tool-output">
					${text && html`<pre>${text}</pre>`}
					${images.map((image) => image.data
						? html`<img src=${`data:${image.mimeType};base64,${image.data}`} alt="Tool image" />`
						: html`<p class="faint small">(image too large to show)</p>`)}
				</div>`
			: null}
	</div>`
}

// MARK: Voice

/** The listener's state when it is listening for this thread. */
function useListen(id) {
	const listen = useData((d) => d.listen)
	return listen?.thread === id ? listen : null
}

/** Reads answers aloud and keeps listening between turns. */
function ReadAloud({ id, onError }) {
	const call = useCall()
	const listen = useListen(id)
	const on = !!listen?.readAloud
	const toggle = () => {
		haptic(call)
		call('listen.readAloud', { id, on: !on }).catch((error) => onError(error.message))
	}
	return html`<button class=${`icon-button glass ${on ? 'on' : ''}`} aria-label="Read aloud" aria-pressed=${on} onClick=${toggle}>
		<${Icon} name=${on ? 'speaker' : 'speakerOff'} />
	</button>`
}

/** What the listener is doing, in a few words. */
function voiceHint(listen, holding) {
	if (!listen) return null
	if (listen.state === 'preparing') return 'Starting the microphone…'
	if (holding === 'hold') return 'Release to send · slide ↑ to lock · ← to cancel'
	if (listen.speaking) return 'Reading · talk to interrupt'
	if (listen.sendsIn != null) return 'Sending · tap the mic to keep it'
	if (listen.awaitingAnswer && !listen.text) return 'Working · the answer will be read'
	if (listen.state === 'on') return listen.text ? 'Pause to send, or say "send it"' : 'Listening'
	return null
}

// MARK: Composer

function Composer({ id, busy, model, onError }) {
	const call = useCall()
	const [drafts, setDrafts] = useUI('drafts', {})
	const listen = useListen(id)
	const active = listen?.state === 'on' || listen?.state === 'preparing'
	const [holding, setHolding] = useState(null)
	const press = useRef(null)
	const field = useRef(null)
	const draft = drafts[id] ?? ''
	const text = active ? [listen.prefix, listen.text].filter(Boolean).join(' ') : draft
	const empty = !text.trim()
	const setDraft = (value) => setDrafts((all) => ({ ...all, [id]: value }))

	useLayoutEffect(() => {
		const el = field.current
		if (!el) return
		el.style.height = 'auto'
		el.style.height = `${Math.min(el.scrollHeight, 160)}px`
	}, [text])

	// The listener sent a turn (with the typed draft before it): the draft is gone.
	const sent = useRef(listen?.sent)
	useEffect(() => {
		if (listen && sent.current != null && listen.sent > sent.current) setDraft('')
		sent.current = listen?.sent
	}, [listen?.sent])
	useEffect(() => {
		if (listen?.error) onError(listen.error)
	}, [listen?.error])

	/** Stops listening and keeps what was said in the draft, to edit. */
	const keep = async () => {
		const { text: kept } = await call('listen.stop')
		if (kept) setDraft(kept)
	}

	const send = async () => {
		if (active) {
			haptic(call)
			return call('listen.send').catch((error) => onError(error.message))
		}
		const value = text.trim()
		if (!value) return
		setDraft('')
		haptic(call)
		try {
			await call('thread.send', { id, text: value })
			onError(null)
		} catch (error) {
			setDraft(value)
			onError(error.message)
		}
	}

	// The mic: hold to talk and let go to send; slide up to lock, left to cancel. A quick tap listens until a pause
	// sends it. Tapping while it listens stops and keeps the words.
	const down = (event) => {
		event.currentTarget.setPointerCapture?.(event.pointerId)
		if (active) {
			press.current = { stop: true }
			return
		}
		press.current = { x: event.clientX, y: event.clientY, at: Date.now() }
		setHolding('hold')
		haptic(call)
		call('listen.start', { id, mode: 'hold', prefix: draft.trim() }).catch((error) => {
			setHolding(null)
			onError(error.message)
		})
	}
	const move = (event) => {
		const p = press.current
		if (!p || p.stop || p.done) return
		if (event.clientY - p.y < -60) {
			p.done = true
			setHolding(null)
			haptic(call)
			call('listen.mode', { mode: 'auto' })
		} else if (event.clientX - p.x < -80) {
			p.done = true
			setHolding(null)
			haptic(call, 'medium')
			call('listen.cancel')
		}
	}
	const up = () => {
		const p = press.current
		press.current = null
		setHolding(null)
		if (!p || p.done) return
		if (p.stop) return keep()
		if (Date.now() - p.at < 350) return call('listen.mode', { mode: 'auto' })
		call('listen.send').catch((error) => onError(error.message))
	}

	const hint = voiceHint(active ? listen : null, holding)
	const counting = active && listen.sendsIn != null
	return html`<div class="composer">
		<div class="row gap chips">
			${hint
				? html`<${Tag} tone="soft">${hint}<//>`
				: html`<${Tag}>${model ?? 'gpt-6.1-sol'}<//><${Tag}>Phone<//>`}
			${busy && !hint && html`<${Tag} tone="soft">${empty ? 'Running' : 'Steer'}<//>`}
		</div>
		<div class="row gap end">
			<textarea ref=${field} class=${`field glass ${active ? 'live' : ''}`} rows="1" aria-label="Message Mycroft"
				placeholder=${active ? 'Listening…' : busy ? 'Steer the run…' : 'Message Mycroft'} value=${text}
				readOnly=${active} onFocus=${active ? keep : undefined}
				onInput=${(event) => setDraft(event.target.value)}></textarea>
			<button class=${`icon-button glass tall mic ${active ? 'listening' : ''} ${holding ? 'held' : ''}`}
				aria-label=${active ? 'Stop listening' : 'Talk'} style=${active ? `--level:${listen.level ?? 0}` : ''}
				onPointerDown=${down} onPointerMove=${move} onPointerUp=${up} onPointerCancel=${up}
				onContextMenu=${(event) => event.preventDefault()}>
				<${Icon} name=${active ? 'wave' : 'mic'} />
			</button>
			${busy && empty && !active
				? html`<button class="round glass" aria-label="Stop" onClick=${() => { haptic(call, 'medium'); call('thread.stop', { id }) }}><${Icon} name="stop" size=${16} stroke=${2.6} /></button>`
				: html`<button class="round glass prominent send" aria-label=${busy ? 'Steer' : 'Send'} disabled=${empty} onClick=${send}>
						${counting && html`<${Countdown} total=${listen.countdown} left=${listen.sendsIn} />`}
						<${Icon} name="up" stroke=${2.4} />
					</button>`}
		</div>
	</div>`
}

/** A ring that fills around the send button until a paused turn sends itself. */
function Countdown({ total, left }) {
	// Started once, with the time left then: later events only confirm it.
	const [start] = useState(() => ({ delay: -(total - left) }))
	return html`<svg class="countdown" viewBox="0 0 48 48" aria-hidden="true">
		<circle cx="24" cy="24" r="22" pathLength="100"
			style=${`animation-duration:${total}ms; animation-delay:${start.delay}ms`} />
	</svg>`
}
