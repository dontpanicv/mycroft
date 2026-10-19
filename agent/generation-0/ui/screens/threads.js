// The home screen: the thread list, sign-in when needed, and the floating new-thread button.

import { html, useState } from '/lib/preact.js'
import { useData, useCall, useNavigation, Icon, Label, Tag, pad, ago, haptic } from '../lib.js'
import { SignIn } from './settings.js'

export function Threads() {
	const state = useData((d) => d.state)
	const call = useCall()
	const { go } = useNavigation()
	const [creating, setCreating] = useState(false)
	const [menu, setMenu] = useState(null)
	const threads = state?.threads ?? []
	const signIn = state?.signIn?.state

	const create = async () => {
		setCreating(true)
		haptic(call)
		try {
			const thread = await call('thread.new')
			go(`#/t/${thread.id}`)
		} finally {
			setCreating(false)
		}
	}

	return html`
		<main class=${`screen scroll ${threads.length ? '' : 'grid'}`}>
			<header class="bar glass-bar">
				<span class="bar-side"></span>
				<${Label} tone="ink">Mycroft<//>
				<button class="icon-button glass" aria-label="Settings" onClick=${() => go('#/settings')}><${Icon} name="gear" /></button>
			</header>

			<section class="hero">
				<h1><span class="soft">Brain on the phone.</span><br />Hands everywhere.</h1>
				<div class="row gap">
					<${Tag} tone="soft">Gen ${state?.generation?.active ?? 0}<//>
					<${Tag} tone=${signIn === 'signedIn' ? '' : 'danger'}>${signIn === 'signedIn' ? 'Sol 6.1' : 'Signed out'}<//>
					${state?.machines?.length ? html`<${Tag}>${state.machines.length} machine${state.machines.length > 1 ? 's' : ''}<//>` : null}
				</div>
			</section>

			${signIn && signIn !== 'signedIn' && signIn !== 'unknown' && html`<div class="gutter"><${SignIn} /></div>`}
			${(state?.notices ?? []).map((notice) => html`<p class="card notice mono small">${notice}</p>`)}

			${threads.length
				? html`<ol class="list">
						${threads.map((thread, index) => html`
							<li>
								<button class="thread-row" onClick=${() => menu || go(`#/t/${thread.id}`)}
									onContextMenu=${(event) => { event.preventDefault(); haptic(call, 'medium'); setMenu(thread) }}
									...${longPress(() => { haptic(call, 'medium'); setMenu(thread) })}>
									<span class="index">${pad(index + 1)}</span>
									<span class="grow">
										<span class="title">${thread.title}</span>
										<span class="meta"><span>${ago(thread.updatedAt)}</span><${Tag}>${thread.machine ?? 'Phone'}<//></span>
									</span>
									<span class="faint"><${Icon} name="out" size=${16} /></span>
								</button>
							</li>`)}
					</ol>`
				: html`<${HowItWorks} />`}
			<div class="spacer"></div>
		</main>

		<button class="fab fab-right glass prominent" aria-label="New thread" disabled=${creating} onClick=${create}>
			<${Icon} name="plus" size=${24} stroke=${2.2} />
		</button>

		${menu && html`<${Sheet} onClose=${() => setMenu(null)}>
			<${Label}>${menu.title}<//>
			<button class="sheet-action danger" onClick=${() => { call('thread.archive', { id: menu.id }); setMenu(null) }}>Archive thread</button>
			<button class="sheet-action" onClick=${() => setMenu(null)}>Cancel</button>
		<//>`}
	`
}

function HowItWorks() {
	const steps = [
		['Start a thread.', 'Each one is a durable conversation that survives iOS killing the app.'],
		['Let it work.', 'Leave the app; the run keeps going in the background and shows its progress.'],
		['Let it grow.', 'Ask Mycroft to change anything about itself — this screen included. It reloads in place.'],
	]
	return html`<section class="gutter how">
		<${Label}>How it works<//>
		${steps.map(([title, detail], i) => html`<p class="step"><span class="index">${pad(i + 1)}</span><span><b>${title}</b> ${detail}</span></p>`)}
	</section>`
}

/** A glass action sheet from the bottom. */
export function Sheet({ children, onClose }) {
	return html`<div class="sheet-backdrop" onClick=${onClose}>
		<div class="sheet glass" onClick=${(event) => event.stopPropagation()}>${children}</div>
	</div>`
}

/** Handlers that call `action` after a 450 ms press without moving. */
function longPress(action) {
	let timer
	const cancel = () => clearTimeout(timer)
	return {
		onTouchStart: () => { timer = setTimeout(action, 450) },
		onTouchMove: cancel,
		onTouchEnd: cancel,
	}
}
