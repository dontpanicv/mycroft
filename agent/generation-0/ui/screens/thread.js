// One thread: the transcript as a console (user turns as bordered blocks, prose, numbered tool rows) and the
// glass composer with dictation, send, steer and stop.

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
		return () => call('thread.close', { id }).catch(() => {})
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
	return html`
		<main class="screen thread">
			<header class="bar glass-bar">
				<button class="icon-button glass" aria-label="Back" onClick=${back}><${Icon} name="back" /></button>
				<div class="bar-title">
					<span class="title mono">${meta?.title ?? 'Thread'}</span>
					<span class=${`label tiny ${busy ? 'soft' : 'faint'}`} id="status">${busy ? 'Running' : 'Idle'}</span>
				</div>
				<span class="bar-side"></span>
				${busy && html`<div class="progress"></div>`}
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

// MARK: Composer

function Composer({ id, busy, model, onError }) {
	const call = useCall()
	const [drafts, setDrafts] = useUI('drafts', {})
	const dictation = useData((d) => d.dictation)
	const [dictating, setDictating] = useState(false)
	const before = useRef('')
	const field = useRef(null)
	const draft = drafts[id] ?? ''
	const text = dictating && dictation?.text ? [before.current, dictation.text].filter(Boolean).join(' ') : draft
	const empty = !text.trim()
	const setDraft = (value) => setDrafts((all) => ({ ...all, [id]: value }))

	useLayoutEffect(() => {
		const el = field.current
		if (!el) return
		el.style.height = 'auto'
		el.style.height = `${Math.min(el.scrollHeight, 160)}px`
	}, [text])

	useEffect(() => {
		if (dictating && dictation?.state === 'failed') {
			setDictating(false)
			onError(dictation.message)
		}
	}, [dictation?.state])

	const send = async () => {
		const value = text.trim()
		if (!value) return
		if (dictating) await toggleDictation()
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

	const toggleDictation = async () => {
		if (dictating) {
			setDictating(false)
			const { text: heard } = await call('dictation.stop')
			setDraft([before.current, heard].filter(Boolean).join(' '))
		} else {
			before.current = draft.trim()
			setDictating(true)
			call('dictation.start').catch((error) => { setDictating(false); onError(error.message) })
		}
	}

	return html`<div class="composer">
		<div class="row gap chips">
			<${Tag}>${model ?? 'gpt-6.1-sol'}<//>
			<${Tag}>Phone<//>
			${busy && html`<${Tag} tone="soft">${empty ? 'Running' : 'Steer'}<//>`}
			${dictating && html`<${Tag} tone="soft">On-device dictation<//>`}
		</div>
		<div class="row gap end">
			<textarea ref=${field} class="field glass" rows="1" aria-label="Message Mycroft"
				placeholder=${busy ? 'Steer the run…' : 'Message Mycroft'} value=${text}
				onInput=${(event) => setDraft(event.target.value)}></textarea>
			<button class=${`icon-button glass tall ${dictating ? 'listening' : ''}`} aria-label=${dictating ? 'Stop dictation' : 'Dictate'}
				onClick=${toggleDictation} style=${dictating ? `--level:${dictation?.level ?? 0}` : ''}>
				<${Icon} name=${dictating ? 'wave' : 'mic'} />
			</button>
			${busy && empty && !dictating
				? html`<button class="round glass" aria-label="Stop" onClick=${() => { haptic(call, 'medium'); call('thread.stop', { id }) }}><${Icon} name="stop" size=${16} stroke=${2.6} /></button>`
				: html`<button class="round glass prominent" aria-label=${busy ? 'Steer' : 'Send'} disabled=${empty} onClick=${send}><${Icon} name="up" stroke=${2.4} /></button>`}
		</div>
	</div>`
}
