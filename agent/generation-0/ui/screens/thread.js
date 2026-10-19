// One thread: the transcript as a console (user turns as bordered blocks, prose, numbered tool rows) and the composer
// (screens/composer.js). A finished run folds its working into "Worked for 1m 05s"; its answer keeps Copy and Fork.
// While a run works, a capsule above the composer shows its time and the queue, and new messages queue or steer.
// `id` null is a new thread's draft: nothing exists until the first message is sent.

import { html, useEffect, useLayoutEffect, useRef, useState } from '/lib/preact.js'
import { useData, useCall, useUI, useNavigation, Icon, Label, Tag, Markdown, Spinner, Sheet, pad, duration, summarize, haptic } from '../lib.js'
import { Composer } from './composer.js'

export function Thread({ id }) {
	const call = useCall()
	const { back, go, replace } = useNavigation()
	const draft = id == null
	const view = useData((d) => (draft ? null : d.views[id]))
	const meta = useData((d) => (draft ? null : [...(d.state?.threads ?? []), ...(d.state?.archived ?? [])].find((t) => t.id === id)))
	const parent = useData((d) => (meta?.parent ? [...(d.state?.threads ?? []), ...(d.state?.archived ?? [])].find((t) => t.id === meta.parent) : null))
	const [, setDrafts] = useUI('drafts', {})
	const [whileWorking] = useUI('whileWorking', 'queue')
	const [error, setError] = useState(null)
	const [sheet, setSheet] = useState(null)
	const scroller = useRef(null)
	const pinned = useRef(true)
	const [atEnd, setAtEnd] = useState(true)

	useEffect(() => {
		if (draft) return () => call('listen.close').catch(() => {})
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
		if (pinned.current !== atEnd) setAtEnd(pinned.current)
	}
	const toEnd = () => {
		const el = scroller.current
		if (!el) return
		el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' })
		pinned.current = true
		setAtEnd(true)
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
	const queued = view?.queued ?? []
	const showProgress = useLinger(busy, 600)

	const submit = async (text, how) => {
		if (draft) {
			const thread = await call('thread.create', { text })
			return replace(`#/t/${thread.id}`)
		}
		await call('thread.send', { id, text, how: how === 'steer' ? 'steer' : 'queue' })
		toEnd()
	}
	/** Puts a queued message back into the composer, to change and send again. */
	const editQueued = async (item) => {
		await call('thread.unqueue', { id, submission: item.id })
		setDrafts((all) => ({ ...all, [id]: [all[id], item.text].filter(Boolean).join('\n') }))
		setSheet(null)
	}

	return html`
		<main class="screen thread">
			<header class="bar glass-bar">
				<button class="icon-button glass" aria-label="Back" onClick=${back}><${Icon} name="back" /></button>
				<button class="bar-title" disabled=${draft} onClick=${() => setSheet('rename')}>
					<span class="title mono">${draft ? 'New thread' : meta?.title ?? 'Thread'}</span>
					<span class=${`label tiny ${busy ? 'soft' : 'faint'}`} id="status">${draft ? 'Draft' : busy ? 'Running' : 'Idle'}</span>
				</button>
				<span class="bar-side"></span>
				${showProgress && html`<div class="progress"></div>`}
			</header>
			<div class="scroll transcript" ref=${scroller} onScroll=${onScroll}>
				${draft
					? html`<section class="draft-hero"><h1>What should Mycroft do?</h1><p class="muted">Type, or hold the mic and talk. The thread starts when you send.</p></section>`
					: view ? html`${parent && html`<button class="forked-from faint small" onClick=${() => go(`#/t/${parent.id}`)}><${Icon} name="fork" size=${13} /> Forked from ${parent.title}</button>`}
						<${Transcript} view=${view} thread=${meta} onError=${setError} onRetry=${(text) => submit(text, 'send')} />`
					: html`<div class="center"><${Spinner} /></div>`}
				${(error || view?.error) && html`<p class="card danger mono small">${error || view.error}</p>`}
				<div class="composer-space"></div>
			</div>
			<${Composer} owner=${draft ? 'new' : id} busy=${busy} preferred=${whileWorking}
				placeholder=${draft ? 'Ask Mycroft anything…' : busy ? (whileWorking === 'steer' ? 'Steer the run…' : 'Queue a message…') : 'Message Mycroft'}
				chips=${html`<${Tag}>${view?.model ?? 'gpt-6.1-sol'}<//><${Tag}>${meta?.machine ?? 'Phone'}<//>`}
				above=${!draft && html`<${RunStatus} view=${view} atEnd=${atEnd} onEnd=${toEnd} onQueue=${() => setSheet('queue')}
					onResume=${() => call('thread.resume', { id }).catch((e) => setError(e.message))} />`}
				onSubmit=${submit} onStop=${() => call('thread.stop', { id })} onError=${setError} />
		</main>
		${sheet === 'queue' && html`<${QueueSheet} id=${id} items=${queued} busy=${busy} onEdit=${editQueued} onError=${setError} onClose=${() => setSheet(null)} />`}
		${sheet === 'rename' && meta && html`<${RenameSheet} thread=${meta} onClose=${() => setSheet(null)} />`}
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

/** The capsule above the composer: "Working 1m 05s", the queue, and a way back to the latest. */
function RunStatus({ view, atEnd, onEnd, onQueue, onResume }) {
	const busy = view?.busy ?? false
	const queued = view?.queued?.length ?? 0
	const since = lastUserTime(view?.entries ?? [])
	const now = useNow(busy)
	if (!busy && !queued && atEnd) return null
	return html`<div class="run-status">
		${(busy || queued > 0) && html`<div class="capsule glass">
			${busy && html`<span class="segment soft"><${Spinner} /> Working${since ? ` ${duration(Math.max(0, now - since))}` : ''}</span>`}
			${!busy && queued > 0 && html`<span class="segment">Queue paused</span>`}
			${queued > 0 && html`<button class="segment link" onClick=${onQueue}><${Icon} name="queue" size=${14} /> ${queued} queued</button>`}
			${!busy && queued > 0 && html`<button class="segment link" onClick=${onResume}><${Icon} name="play" size=${13} /> Resume</button>`}
		</div>`}
		${!atEnd && html`<button class="icon-button glass small-icon to-end" aria-label="Scroll to end" onClick=${onEnd}><${Icon} name="down" size=${16} /></button>`}
	</div>`
}

/** The current time, ticking every second while `on`. */
function useNow(on) {
	const [now, setNow] = useState(Date.now())
	useEffect(() => {
		if (!on) return
		const timer = setInterval(() => setNow(Date.now()), 1000)
		return () => clearInterval(timer)
	}, [on])
	return on ? now : Date.now()
}

const timeOf = (message) => (message?.timestamp ? new Date(message.timestamp).getTime() : null)
function lastUserTime(entries) {
	for (let i = entries.length - 1; i >= 0; i--) {
		const message = entries[i].model?.[0]
		if (message?.role === 'user') return timeOf(message)
	}
	return null
}

/** Queued messages: steer one into the run now, edit it (back into the composer), or remove it. */
function QueueSheet({ id, items, busy, onEdit, onError, onClose }) {
	const call = useCall()
	const act = (op, item) => call(op, { id, submission: item.id }).catch((e) => onError(e.message))
	useEffect(() => {
		if (!items.length) onClose()
	}, [items.length])
	return html`<${Sheet} onClose=${onClose}>
		<${Label}>Queued · sent in order after the run<//>
		${items.map((item, index) => html`<div class="queue-item">
			<span class="index">${pad(index + 1)}</span>
			<span class="grow"><span class="queue-text">${item.text}</span>${item.mode === 'steer' && html`<${Tag} tone="soft">Steer<//>`}</span>
			<div class="row gap">
				${busy && item.mode !== 'steer' && html`<button class="button small glass" onClick=${() => { haptic(call); act('thread.steerNow', item) }}>Steer now</button>`}
				<button class="button small glass" onClick=${() => onEdit(item)}>Edit</button>
				<button class="button small glass danger" aria-label="Remove" onClick=${() => { haptic(call, 'medium'); act('thread.unqueue', item) }}><${Icon} name="trash" size=${15} /></button>
			</div>
		</div>`)}
		<button class="sheet-action" onClick=${onClose}>Done</button>
	<//>`
}

/** Renames a thread. Also used from the thread list. */
export function RenameSheet({ thread, onClose }) {
	const call = useCall()
	const [title, setTitle] = useState(thread.title)
	const [error, setError] = useState(null)
	const save = async (event) => {
		event?.preventDefault()
		try {
			await call('thread.rename', { id: thread.id, title })
			haptic(call, 'success')
			onClose()
		} catch (e) {
			setError(e.message)
		}
	}
	return html`<${Sheet} onClose=${onClose}>
		<${Label}>Rename thread<//>
		<form class="stack" onSubmit=${save}>
			<input class="input title-input" value=${title} autofocus aria-label="Thread title" onInput=${(e) => setTitle(e.target.value)} />
			${error && html`<p class="danger small">${error}</p>`}
			<button class="button glass prominent wide" type="submit" disabled=${!title.trim()}>Save</button>
		</form>
		<button class="sheet-action" onClick=${onClose}>Cancel</button>
	<//>`
}

// MARK: Transcript

/** The entries as turns: each user message with the work and the answer that followed it. */
function turnsOf(entries) {
	const turns = []
	for (const entry of entries) {
		const message = entry.model?.[0]
		if (!message) continue
		if (message.role === 'user' || !turns.length) turns.push({ user: message.role === 'user' ? entry : null, replies: [] })
		if (message.role !== 'user') turns[turns.length - 1].replies.push(entry)
	}
	return turns
}

function Transcript({ view, thread, onError, onRetry }) {
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
	const turns = turnsOf(entries)
	const lastAnswer = [...entries].reverse().find((e) => e.model?.[0]?.role === 'assistant')?.model?.[0]
	const lastUser = [...entries].reverse().find((e) => e.model?.[0]?.role === 'user')?.model?.[0]
	const props = { results, numbers, live: liveTools }

	return html`
		${turns.map((turn, index) => {
			const current = index === turns.length - 1 && view.busy
			return html`
				${turn.user && html`<${UserTurn} key=${turn.user.id} message=${turn.user.model[0]} />`}
				${current
					? turn.replies.map((entry) => entry.model[0].role === 'assistant' && html`<${AssistantTurn} key=${entry.id} message=${entry.model[0]} ...${props} />`)
					: html`<${FinishedRun} key=${`run-${turn.user?.id ?? index}`} turn=${turn} thread=${thread} props=${props} onError=${onError} />`}`
		})}
		${streaming
			? html`<${AssistantTurn} message=${streaming} ...${props} />`
			: view.busy && html`<div class="row gap soft working"><${Spinner} /><${Label} tone="soft">${liveTools.length ? 'Working' : 'Thinking'}<//></div>`}
		${!view.busy && lastAnswer?.errorMessage && html`<div class="card danger stack">
			<p class="mono small">${lastAnswer.errorMessage}</p>
			${lastUser && html`<button class="button small glass" onClick=${() => onRetry(textOf(lastUser))}><${Icon} name="retry" size=${14} /> Retry</button>`}
		</div>`}
	`
}

/**
 * A run that ended: its working (thinking, tool calls, the messages in between) folds into "Worked for …", and the
 * final answer stays, with Copy, Fork and its time.
 */
function FinishedRun({ turn, thread, props, onError }) {
	const call = useCall()
	const { go } = useNavigation()
	const [open, setOpen] = useState(false)
	const [copied, setCopied] = useState(false)
	const replies = turn.replies.filter((e) => e.model[0].role === 'assistant')
	const final = replies[replies.length - 1]
	if (!final) return null
	const finalMessage = final.model[0]
	const answer = textOf(finalMessage)
	const work = [...replies.slice(0, -1).map((e) => e.model[0]), { ...finalMessage, content: (finalMessage.content ?? []).filter((b) => b.type !== 'text') }]
	const steps = work.flatMap((m) => m.content ?? []).filter((b) => b.type === 'toolCall').length
	const start = timeOf(turn.user?.model?.[0])
	const end = (timeOf(finalMessage) ?? 0) + (finalMessage.durationMs ?? 0)
	const folds = steps > 0 || replies.length > 1

	const copy = () => {
		call('clipboard.copy', { text: answer })
		haptic(call)
		setCopied(true)
		setTimeout(() => setCopied(false), 1500)
	}
	const fork = async () => {
		haptic(call, 'medium')
		try {
			const forked = await call('thread.fork', { id: thread.id, entry: final.id })
			go(`#/t/${forked.id}`)
		} catch (e) {
			onError(e.message)
		}
	}
	return html`<div class="assistant-turn">
		${folds
			? html`<button class="disclosure worked" aria-expanded=${open} onClick=${() => setOpen(!open)}>
					<${Icon} name=${open ? 'down' : 'chevron'} size=${12} />
					<${Label} tone="faint" size=${9.5}>${finalMessage.stopReason === 'aborted' ? 'Stopped after' : 'Worked for'} ${start && end > start ? duration(end - start) : '…'}${steps ? ` · ${steps} step${steps > 1 ? 's' : ''}` : ''}<//>
				</button>
				${open && work.map((message, i) => html`<${AssistantTurn} key=${i} message=${message} ...${props} />`)}`
			: work.map((message, i) => html`<${AssistantTurn} key=${i} message=${message} ...${props} />`)}
		${answer && html`<${Markdown} text=${answer} />`}
		${answer && thread && html`<div class="answer-actions">
			<button class="answer-action" aria-label="Copy answer" onClick=${copy}><${Icon} name=${copied ? 'check' : 'copy'} size=${14} /></button>
			<button class="answer-action" aria-label="Fork from this answer" onClick=${fork}><${Icon} name="fork" size=${14} /></button>
			${end > 0 && html`<span class="faint mono tiny">${new Date(end).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}</span>`}
		</div>`}
	</div>`
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
