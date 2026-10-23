// The glass composer at the bottom of a thread (and of a new thread's draft): the field, the mic and send.
//
// Dictation works like a WhatsApp voice note, but the words land in the field (the app's `listen` events):
// - hold the mic and talk; let go to send. Slide left to cancel, slide up to lock it on.
// - a quick tap also locks it on. While locked: the trash cancels, the mic stops and keeps the words in the field to
//   edit, send sends.
// Nothing is sent on a pause; the user starts and stops. ✕ in the field clears it, also while listening (start over).
// The wave next to the mic starts a conversation in the thread instead (screens/talk.js).

import { html, useEffect, useLayoutEffect, useRef, useState } from '/lib/preact.js'
import { useData, useCall, useUI, Icon, Label, Tag, Sheet, haptic } from '../lib.js'

/** The listener's state while it listens for this composer. The app reports `owner` as a string; thread ids are
 * numbers. */
function useListen(owner) {
	const listen = useData((d) => d.listen)
	return listen?.owner === String(owner) ? listen : null
}

const clock = (ms) => `${Math.floor(ms / 60000)}:${String(Math.floor(ms / 1000) % 60).padStart(2, '0')}`

/**
 * `owner` keys the draft and the listener (a thread id, or 'new'). `onSubmit(text, how)` sends; `how` is 'send', or
 * 'queue' / 'steer' while `busy` (`preferred` is the setting; a long press on send offers the other). `onStop` stops
 * the run. `onTalk` starts a conversation (no button without it). `above` sits over the composer (the run's status).
 */
export function Composer({ owner, busy, preferred = 'queue', above, placeholder, onSubmit, onStop, onTalk, onError }) {
	const call = useCall()
	const [drafts, setDrafts] = useUI('drafts', {})
	const listen = useListen(owner)
	const active = listen?.state === 'on' || listen?.state === 'preparing'
	// 'hold' while the mic is held; 'locked' after sliding up or a tap.
	const [gesture, setGesture] = useState(null)
	const [choosing, setChoosing] = useState(false)
	const holding = gesture === 'hold'
	// Feedback from the first touch, before the microphone has started.
	const recording = active || gesture != null
	const sendPress = useRef(null)
	const press = useRef(null)
	const field = useRef(null)
	const draft = drafts[owner] ?? ''
	const text = active ? [listen.prefix, listen.text].filter(Boolean).join(' ') : draft
	const empty = !text.trim()
	const setDraft = (value) => setDrafts((all) => ({ ...all, [owner]: value }))
	const how = busy ? preferred : 'send'

	useLayoutEffect(() => {
		const el = field.current
		if (!el) return
		el.style.height = 'auto'
		el.style.height = `${Math.min(el.scrollHeight, 160)}px`
	}, [text])
	useEffect(() => {
		if (!listen?.error) return
		onError(listen.error)
		setGesture(null)
	}, [listen?.error])
	useEffect(() => {
		if (!active && gesture === 'locked') setGesture(null)
	}, [active])

	/** Stops listening; the words (after the typed draft) come back. */
	const stopListening = async () => {
		const { text: kept } = await call('listen.stop')
		setGesture(null)
		return kept ?? ''
	}
	/** Stops listening and keeps the words in the field, to edit. */
	const keep = async () => {
		const kept = await stopListening()
		// Nothing comes back if it never started: the typed draft stays.
		if (kept) setDraft(kept)
		field.current?.focus()
	}
	const submit = async (how) => {
		haptic(call)
		const value = (active ? await stopListening() : text).trim()
		if (!value) return setDraft('')
		setDraft('')
		try {
			await onSubmit(value, how)
			onError(null)
		} catch (error) {
			setDraft(value)
			onError(error.message)
		}
	}
	const cancel = () => {
		haptic(call, 'medium')
		setGesture(null)
		call('listen.cancel')
	}
	const clear = () => {
		haptic(call)
		if (active) call('listen.clear')
		else setDraft('')
	}

	// The mic: hold to talk and let go to send; slide up to lock, left to cancel. A quick tap locks it on.
	const down = (event) => {
		event.currentTarget.setPointerCapture?.(event.pointerId)
		if (recording) {
			press.current = { stop: true }
			return
		}
		press.current = { x: event.clientX, y: event.clientY, at: Date.now() }
		setGesture('hold')
		haptic(call)
		call('listen.start', { owner: String(owner), prefix: draft.trim() }).catch((error) => {
			setGesture(null)
			onError(error.message)
		})
	}
	const move = (event) => {
		const p = press.current
		if (!p || p.stop || p.done) return
		if (event.clientY - p.y < -60) {
			p.done = true
			setGesture('locked')
			haptic(call)
		} else if (event.clientX - p.x < -80) {
			p.done = true
			cancel()
		}
	}
	const up = () => {
		const p = press.current
		press.current = null
		if (!p || p.done) return
		if (p.stop) return keep()
		if (Date.now() - p.at < 350) return setGesture('locked')
		setGesture(null)
		submit(how)
	}

	// Send: a tap uses the preferred way while a run works; holding it offers both.
	const sendDown = () => {
		if (!busy) return
		sendPress.current = { timer: setTimeout(() => {
			sendPress.current = { menu: true }
			haptic(call, 'medium')
			setChoosing(true)
		}, 450) }
	}
	const sendUp = () => clearTimeout(sendPress.current?.timer)
	const sendTap = () => {
		const menu = sendPress.current?.menu
		sendPress.current = null
		if (!menu) submit(how)
	}
	const choose = (way) => {
		setChoosing(false)
		submit(way)
	}

	return html`<div class="composer">
		${above}
		${recording && html`<div class="row gap chips recording">
			${!holding && html`<button class="icon-button glass small-icon danger" aria-label="Cancel dictation" onClick=${cancel}><${Icon} name="trash" size=${17} /></button>`}
			<span class="rec-dot"></span><span class="mono small">${clock(listen?.elapsed ?? 0)}</span>
			<${Tag} tone="soft">${holding ? '‹ Slide to cancel · ↑ to lock'
				: !active || listen.state === 'preparing' ? 'Starting the microphone…'
				: 'Listening · tap ■ to edit'}<//>
		</div>`}
		<div class="row gap end">
			<div class="field-wrap">
				<textarea ref=${field} class=${`field glass ${active ? 'live' : ''}`} rows="1" aria-label="Message Mycroft"
					placeholder=${active ? 'Listening…' : placeholder} value=${text}
					readOnly=${active} onFocus=${active ? keep : undefined}
					onInput=${(event) => setDraft(event.target.value)}></textarea>
				${!empty && html`<button class="clear" aria-label="Clear" onClick=${clear}><${Icon} name="close" size=${14} stroke=${2.2} /></button>`}
			</div>
			${onTalk && !recording && html`<button class="icon-button glass tall talk-button" aria-label="Talk with Mycroft"
				onClick=${() => { haptic(call, 'medium'); onTalk() }}><${Icon} name="wave" /></button>`}
			<div class="mic-wrap">
				${holding && html`<div class="lock-hint glass" aria-hidden="true"><${Icon} name="lock" size=${15} /><${Icon} name="up" size=${13} /></div>`}
				<button class=${`icon-button glass tall mic ${recording ? 'listening' : ''} ${holding ? 'held' : ''}`}
					aria-label=${recording && !holding ? 'Stop listening' : 'Talk'} style=${active ? `--level:${listen.level ?? 0}` : ''}
					onPointerDown=${down} onPointerMove=${move} onPointerUp=${up} onPointerCancel=${up}
					onContextMenu=${(event) => event.preventDefault()}>
					<${Icon} name=${recording && !holding ? 'stop' : 'mic'} />
				</button>
			</div>
			${busy && empty && !active
				? html`<button class="round glass" aria-label="Stop" onClick=${() => { haptic(call, 'medium'); onStop() }}><${Icon} name="stop" size=${16} stroke=${2.6} /></button>`
				: html`<button class="round glass prominent send" aria-label=${how === 'queue' ? 'Queue' : how === 'steer' ? 'Steer' : 'Send'}
						disabled=${empty && !active} onPointerDown=${sendDown} onPointerUp=${sendUp} onPointerLeave=${sendUp} onClick=${sendTap}
						onContextMenu=${(event) => event.preventDefault()}>
						<${Icon} name=${how === 'queue' ? 'queue' : how === 'steer' ? 'steer' : 'up'} stroke=${2.4} />
					</button>`}
		</div>
		${choosing && html`<${Sheet} onClose=${() => setChoosing(false)}>
			<${Label}>Mycroft is working<//>
			<button class="sheet-action choice" onClick=${() => choose('queue')}><b>Queue</b><span class="faint small">Run after the current turn</span></button>
			<button class="sheet-action choice" onClick=${() => choose('steer')}><b>Steer now</b><span class="faint small">Hand it to Mycroft at its next step</span></button>
			<button class="sheet-action" onClick=${() => setChoosing(false)}>Cancel</button>
		<//>`}
	</div>`
}
