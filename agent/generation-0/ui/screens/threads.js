// The home screen: the thread list, sign-in when needed, and the floating new-thread button.
//
// Top to bottom: an unsent new-thread draft, pinned threads, active threads, then a "Settled (N)" shelf, collapsed by
// default. A thread settles by hand (swipe left, or the long-press menu) or after three idle days; sending to it brings
// it back. Each row says what needs the user: Working, Failed, or Done (an answer they haven't opened yet).

import { html, useState } from '/lib/preact.js'
import { useData, useCall, useUI, useNavigation, Icon, Label, Tag, Sheet, Spinner, ago, haptic } from '../lib.js'
import { SignIn } from './settings.js'
import { RenameSheet } from './thread.js'

const settleAfter = 3 * 86_400_000
const time = (date) => (date ? new Date(date).getTime() : 0)

/** What a row shows: 'working', 'failed', 'done' (unread) or null; and whether it belongs in Settled. */
export function standing(thread, busy) {
	const working = busy.includes(thread.id)
	const status = working ? 'working'
		: thread.outcome === 'failed' ? 'failed'
		: thread.finishedAt && time(thread.finishedAt) > time(thread.visitedAt) ? 'done'
		: null
	const idleSince = Math.max(time(thread.updatedAt), time(thread.unsettledAt), time(thread.finishedAt))
	const settled = !working && !thread.pinned && (!!thread.settledAt || (status !== 'done' && Date.now() - idleSince > settleAfter))
	return { status, settled }
}

export function Threads() {
	const state = useData((d) => d.state)
	const call = useCall()
	const { go } = useNavigation()
	const [drafts, setDrafts] = useUI('drafts', {})
	const [settledOpen, setSettledOpen] = useUI('settledOpen', false)
	const [shown, setShown] = useState(10)
	const [menu, setMenu] = useState(null)
	const [renaming, setRenaming] = useState(null)
	const threads = state?.threads ?? []
	const busy = state?.busy ?? []
	const signIn = state?.signIn?.state
	const draft = (drafts.new ?? '').trim()

	const rows = threads.map((thread) => ({ thread, ...standing(thread, busy) }))
	const pinned = rows.filter((r) => r.thread.pinned && !r.settled)
	const active = rows.filter((r) => !r.thread.pinned && !r.settled)
	const settled = rows.filter((r) => r.settled)
		.sort((a, b) => time(b.thread.settledAt ?? b.thread.updatedAt) - time(a.thread.settledAt ?? a.thread.updatedAt))
	const archived = state?.archived?.length ?? 0

	const settle = (thread, on) => {
		haptic(call, 'medium')
		call('thread.settle', { id: thread.id, on })
	}
	const act = (op, args) => {
		call(op, { id: menu.thread.id, ...args })
		setMenu(null)
	}
	const open = (thread) => go(`#/t/${thread.id}`)

	const openCount = pinned.length + active.length + (draft ? 1 : 0)
	return html`
		<main class=${`screen scroll ${openCount ? '' : 'grid'}`}>
			<header class="bar glass-bar">
				<span class="bar-side"></span>
				<${Label} tone="ink">Mycroft<//>
				<button class="icon-button glass" aria-label="Settings" onClick=${() => go('#/settings')}><${Icon} name="gear" /></button>
			</header>

			${signIn && signIn !== 'signedIn' && signIn !== 'unknown' && html`<div class="gutter top-gap"><${SignIn} /></div>`}
			${(state?.notices ?? []).map((notice) => html`<p class="card notice mono small">${notice}</p>`)}

			${threads.length || draft
				? html`${openCount
						? html`<ol class="list">
						${draft && html`<li><${Row} title=${draft.split('\n')[0]} label="Draft" onOpen=${() => go('#/new')}
							onMenu=${() => setMenu({ draft: true })} /></li>`}
						${[...pinned, ...active].map(({ thread, status }) => html`<li key=${thread.id}>
							<${Row} title=${thread.title} thread=${thread} status=${status} onOpen=${() => open(thread)}
								onMenu=${() => setMenu({ thread, status })} swipe=${{ label: 'Settle', run: () => settle(thread, true) }} />
						</li>`)}
					</ol>`
						: html`<section class="caught-up">
							<span class="caught-up-mark"><${Icon} name="check" size=${22} stroke=${2.2} /></span>
							<h2>All settled</h2>
							<button class="button glass prominent" onClick=${() => { haptic(call); go('#/new') }}><${Icon} name="plus" size=${15} stroke=${2.2} /> New thread</button>
						</section>`}
					${settled.length > 0 && html`<button class="shelf" aria-expanded=${settledOpen} onClick=${() => setSettledOpen(!settledOpen)}>
						<${Label}>${settledOpen ? 'Settled' : `Settled (${settled.length})`}<//><span class="rule"></span>
						<${Icon} name=${settledOpen ? 'down' : 'chevron'} size=${14} />
					</button>`}
					${settledOpen && html`<ol class="list slim">
						${settled.slice(0, shown).map(({ thread, status }) => html`<li key=${thread.id}>
							<${Row} slim title=${thread.title} thread=${thread} status=${status} onOpen=${() => open(thread)}
								onMenu=${() => setMenu({ thread, status, settled: true })} swipe=${{ label: 'Un-settle', run: () => settle(thread, false) }} />
						</li>`)}
					</ol>
					${settled.length > shown && html`<button class="more" onClick=${() => setShown(shown + 25)}>Show ${Math.min(25, settled.length - shown)} more</button>`}`}
					${archived > 0 && html`<button class="more" onClick=${() => go('#/archived')}>Archived (${archived})</button>`}`
				: html`<section class="caught-up">
						<h2>No threads yet</h2>
						<button class="button glass prominent" onClick=${() => { haptic(call); go('#/new') }}><${Icon} name="plus" size=${15} stroke=${2.2} /> New thread</button>
					</section>`}
			<div class="spacer"></div>
		</main>

		${openCount > 0 && html`<button class="fab fab-right glass prominent" aria-label="New thread" onClick=${() => { haptic(call); go('#/new') }}>
			<${Icon} name="plus" size=${24} stroke=${2.2} />
		</button>`}

		${menu?.draft && html`<${Sheet} onClose=${() => setMenu(null)}>
			<${Label}>Draft<//>
			<button class="sheet-action danger" onClick=${() => { setDrafts((all) => ({ ...all, new: '' })); setMenu(null) }}>Discard draft</button>
			<button class="sheet-action" onClick=${() => setMenu(null)}>Cancel</button>
		<//>`}
		${menu?.thread && html`<${Sheet} onClose=${() => setMenu(null)}>
			<${Label}>${menu.thread.title}<//>
			${!menu.settled && html`<button class="sheet-action" onClick=${() => act('thread.pin', { on: !menu.thread.pinned })}>${menu.thread.pinned ? 'Unpin' : 'Pin to the top'}</button>`}
			<button class="sheet-action" onClick=${() => { setRenaming(menu.thread); setMenu(null) }}>Rename</button>
			<button class="sheet-action" onClick=${() => act('thread.settle', { on: !menu.settled })}>${menu.settled ? 'Un-settle' : 'Settle'}</button>
			<button class="sheet-action danger" disabled=${menu.status === 'working'} onClick=${() => act('thread.archive', { on: true })}>
				${menu.status === 'working' ? 'Archive (stop the run first)' : 'Archive'}</button>
			<button class="sheet-action" onClick=${() => setMenu(null)}>Cancel</button>
		<//>`}
		${renaming && html`<${RenameSheet} thread=${renaming} onClose=${() => setRenaming(null)} />`}
	`
}

const statusLabels = { working: ['Working', 'soft'], failed: ['Failed', 'danger'], done: ['Done', 'success'] }

/** One thread in the list: tap to open, long-press for the menu, swipe left for `swipe.run`. */
function Row({ title, thread, status, label, slim, swipe, onOpen, onMenu }) {
	const call = useCall()
	const [dx, setDx] = useState(0)
	const [gesture] = useState(() => ({}))
	const armed = dx < -90

	const start = (event) => {
		const touch = event.touches[0]
		Object.assign(gesture, { x: touch.clientX, y: touch.clientY, swiping: false, moved: false })
		gesture.timer = setTimeout(() => {
			if (gesture.moved) return
			gesture.menu = true
			haptic(call, 'medium')
			onMenu()
		}, 450)
	}
	const move = (event) => {
		const touch = event.touches[0]
		const x = touch.clientX - gesture.x
		const y = touch.clientY - gesture.y
		if (Math.abs(x) > 8 || Math.abs(y) > 8) {
			gesture.moved = true
			clearTimeout(gesture.timer)
		}
		if (!swipe || (!gesture.swiping && (Math.abs(y) > Math.abs(x) || x > 0))) return
		gesture.swiping = true
		const next = Math.min(0, x)
		if ((next < -90) !== armed) haptic(call)
		setDx(next)
	}
	const end = () => {
		clearTimeout(gesture.timer)
		if (gesture.swiping && armed) swipe.run()
		setDx(0)
	}
	const click = () => {
		if (gesture.menu || gesture.swiping) {
			gesture.menu = false
			gesture.swiping = false
			return
		}
		onOpen()
	}

	const [statusText, tone] = statusLabels[status] ?? []
	const spoken = [title, label ?? ago(thread.updatedAt), thread?.machine, statusText].filter(Boolean).join(' · ')
	return html`<div class="swipe-row">
		${swipe && dx < 0 && html`<div class=${`swipe-action ${armed ? 'armed' : ''}`}><span>${swipe.label}</span></div>`}
		<button class=${`thread-row ${slim ? 'slim' : ''} ${status === 'working' ? 'recede' : ''}`} style=${dx ? `transform: translateX(${dx}px); transition: none` : ''} aria-label=${spoken}
			onClick=${click} onTouchStart=${start} onTouchMove=${move} onTouchEnd=${end} onTouchCancel=${end}
			onContextMenu=${(event) => { event.preventDefault(); haptic(call, 'medium'); onMenu() }}>
			<span class="grow">
				<span class="title">${thread?.pinned && html`<${Icon} name="pin" size=${12} /> `}${title}</span>
				${!slim && html`<span class="meta">
					${label ? html`<${Tag} tone="warning">${label}<//>` : html`<span>${ago(thread.updatedAt)}</span>${thread.machine && html`<${Tag}>${thread.machine}<//>`}`}
				</span>`}
			</span>
			${statusText
				? html`<span class=${`row-status ${tone}`}>${status === 'working' && html`<${Spinner} />`}${statusText}</span>`
				: slim ? html`<span class="faint small">${ago(thread.updatedAt)}</span>` : null}
		</button>
	</div>`
}

/** Archived threads, to bring back. */
export function Archived() {
	const call = useCall()
	const { back, go } = useNavigation()
	const archived = useData((d) => d.state?.archived ?? [])
	return html`<main class="screen scroll">
		<header class="bar glass-bar">
			<button class="icon-button glass" aria-label="Back" onClick=${back}><${Icon} name="back" /></button>
			<${Label} tone="ink">Archived<//>
			<span class="bar-side"></span>
		</header>
		<ol class="list">
			${archived.map((thread) => html`<li key=${thread.id}><div class="thread-row">
				<button class="grow archived-open" onClick=${() => go(`#/t/${thread.id}`)}>
					<span class="title">${thread.title}</span><span class="meta"><span>${ago(thread.updatedAt)}</span></span>
				</button>
				<button class="button small glass" onClick=${() => { haptic(call); call('thread.archive', { id: thread.id, on: false }) }}>Unarchive</button>
			</div></li>`)}
		</ol>
		${!archived.length && html`<p class="gutter muted">Nothing archived.</p>`}
		<div class="spacer"></div>
	</main>`
}
