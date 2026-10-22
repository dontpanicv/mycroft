// Settings: paired machines, the model new threads use and the ChatGPT sign-in, the conversation voice, sending while
// Mycroft works, notices, and Mycroft's generations as a tree.

import { html, useEffect, useState } from '/lib/preact.js'
import { useData, useCall, useUI, useNavigation, Icon, Label, Tag, Spinner, pad, ago, haptic } from '../lib.js'

function Page({ title, children }) {
	const { back } = useNavigation()
	return html`<main class="screen scroll">
		<header class="bar glass-bar">
			<button class="icon-button glass" aria-label="Back" onClick=${back}><${Icon} name="back" /></button>
			<${Label} tone="ink">${title}<//>
			<span class="bar-side"></span>
		</header>
		<div class="gutter stack">${children}</div>
		<div class="spacer"></div>
	</main>`
}

function Section({ title, children }) {
	return html`<section class="section"><${Label}>${title}<//>${children}</section>`
}

export function Settings() {
	const state = useData((d) => d.state)
	return html`<${Page} title="Settings">
		<${Section} title="Machines"><${Machines} machines=${state?.machines ?? []} /><//>
		<${Section} title="Model"><${Brain} brain=${state?.brain} /><${SignIn} /><//>
		<${Section} title="Conversation voice"><${Voice} voice=${state?.voice} /><//>
		<${Section} title="While Mycroft works"><${WhileWorking} /><//>
		<${Section} title="About"><${About} /><//>
		<${Section} title="Self"><${Generations} generation=${state?.generation} /><//>
	<//>`
}

/** ChatGPT subscription sign-in with a device code. */
export function SignIn() {
	const call = useCall()
	const signIn = useData((d) => d.state?.signIn ?? { state: 'unknown' })
	const [working, setWorking] = useState(false)
	const start = () => {
		setWorking(true)
		call('signin.start').finally(() => setTimeout(() => setWorking(false), 1500))
	}
	const button = html`<button class="button glass prominent wide" disabled=${working} onClick=${start}>${working ? 'Waiting…' : 'Sign in with ChatGPT'}</button>`
	switch (signIn.state) {
		case 'signedIn':
			return html`<div class="card row between">
				<div><p class="mono strong">ChatGPT</p><p class="muted small">Signed in, for Sol 6.1.</p></div>
				<button class="button glass" onClick=${() => call('signin.signOut')}>Sign out</button>
			</div>`
		case 'waiting': {
			const page = new URL(signIn.url)
			return html`<div class="card stack">
				<p class="muted small">Your sign-in code</p>
				<p class="code">${signIn.code}</p>
				<button class="button glass prominent wide" onClick=${() => call('signin.open', { url: signIn.url, code: signIn.code })}>Copy code & open sign-in</button>
				<p class="faint small">Paste the code on the page, approve, then close the page. Or enter it at ${page.host}${page.pathname} on any other device. Keep Mycroft open until it says you're signed in.</p>
				<div class="row gap soft"><${Spinner} /><${Label} size=${10}>Waiting for approval<//></div>
			</div>`
		}
		case 'failed':
			return html`<div class="card stack"><p class="danger mono small">${signIn.message}</p>${button}</div>`
		default:
			return html`<div class="card stack"><p>Sign in with your ChatGPT subscription to use Sol 6.1.</p>${button}</div>`
	}
}

const brains = [
	{ id: 'sol', name: 'Sol 6.1', about: 'Your ChatGPT subscription. Every tool: machines, desktop, self-editing.' },
	{ id: 'apple', name: 'Apple on-device', about: 'Experimental. Runs on this iPhone, no sign-in, but a small memory and no machine tools.' },
]

/** The model new threads think with. A thread keeps the model it started with. */
function Brain({ brain }) {
	const call = useCall()
	if (!brain) return null
	const options = brains.map((option) => ({ ...option, disabled: option.id === 'apple' && brain.appleUnavailable && brain.model !== 'apple' }))
	return html`<${Choices} label="Model for new threads" options=${options} chosen=${brain.model}
		onChoose=${(model) => call('brain.choose', { brain: model })}>
		${brain.appleUnavailable && html`<p class="faint small">${brain.appleUnavailable}</p>`}
		<p class="faint small">For new threads; a thread keeps its model.</p>
	<//>`
}

/** The voice Mycroft speaks with in a conversation. Choosing one plays a sample. */
function Voice({ voice }) {
	const call = useCall()
	const [error, setError] = useState(null)
	if (!voice) return null
	if (!voice.bundled) return html`<div class="card"><p class="faint small">This build doesn't include Mycroft's voice (Phonon), so there is no conversation mode.</p></div>`
	const options = voice.voices.map((v) => ({ id: v.id, name: v.name, about: v.accent }))
	const choose = (id) => call('voice.choose', { voice: id }).then(() => setError(null), (e) => setError(e.message))
	return html`<${Choices} label="Conversation voice" options=${options} chosen=${voice.voice} onChoose=${choose}>
		${error && html`<p class="danger small">${error}</p>`}
		<p class="faint small">Phonon by Gradium, on this iPhone. Talk with Mycroft from the wave next to the mic in a thread.</p>
	<//>`
}

const ways = [
	{ id: 'queue', name: 'Queue', about: 'Sent when the current run finishes.' },
	{ id: 'steer', name: 'Steer', about: 'Reaches Mycroft at its next step.' },
]

/** What send does while a run is going. Holding send offers the other way. */
function WhileWorking() {
	const [way, setWay] = useUI('whileWorking', 'queue')
	return html`<${Choices} label="While Mycroft works" options=${ways} chosen=${way} onChoose=${setWay}>
		<p class="faint small">Hold send for the other.</p>
	<//>`
}

/** A card of options, one chosen (a check), with notes under them. */
function Choices({ label, options, chosen, onChoose, children }) {
	const call = useCall()
	const choose = (id) => {
		if (id === chosen) return
		haptic(call)
		onChoose(id)
	}
	return html`<div class="card list-card" role="radiogroup" aria-label=${label}>
		${options.map((option) => html`<button class="choice-row" role="radio" aria-checked=${option.id === chosen}
			aria-label=${option.name} disabled=${option.disabled} onClick=${() => choose(option.id)}>
			<span class="grow"><span class="mono strong block">${option.name}</span><span class="faint small about">${option.about}</span></span>
			${option.id === chosen && html`<${Icon} name="check" size=${18} stroke=${2.4} />`}
		</button>`)}
		${children}
	</div>`
}

/**
 * The generations newest first, each with its lane in the graph, as `git log --graph` draws it. A lane waits for a
 * parent: a generation takes the lane waiting for it (or a new one, at a branch's tip), and the other lanes waiting for
 * it end there, where branches split. `before` and `after` are the lanes above and below its row.
 */
export function graph(history) {
	const rows = []
	let lanes = []
	for (const record of [...history].sort((a, b) => b.generation - a.generation)) {
		const parent = record.parent ?? (record.generation > 0 ? record.generation - 1 : null)
		const before = lanes
		const waiting = before.flatMap((waits, index) => (waits === record.generation ? [index] : []))
		const after = [...before]
		for (const index of waiting) after[index] = null
		let lane = waiting[0] ?? after.indexOf(null)
		if (lane < 0) lane = after.length
		after[lane] = parent
		while (after.length && after[after.length - 1] === null) after.pop()
		rows.push({ record, lane, before, after })
		lanes = after
	}
	return rows
}

const laneWidth = 14
const dotY = 20
const laneX = (lane) => 7 + lane * laneWidth

/** One row's piece of the graph: lanes passing by, the generation's dot, and the lines into it from above and below. */
function GraphCell({ row, lanes, active }) {
	const { record, lane, before, after } = row
	const x = laneX(lane)
	return html`<span class="gen-graph" style=${{ width: `${lanes * laneWidth}px` }} aria-hidden="true"><svg>
		${before.map((waits, index) => waits === null ? null
			: waits === record.generation
				? html`<line x1=${laneX(index)} y1="0" x2=${x} y2=${dotY} />`
				: html`<line x1=${laneX(index)} y1="0" x2=${laneX(index)} y2="100%" />`)}
		${after[lane] != null && html`<line x1=${x} y1=${dotY} x2=${x} y2="100%" />`}
		<circle cx=${x} cy=${dotY} r="4" class=${record.generation === active ? 'active' : ''} />
	</svg></span>`
}

/** Mycroft's generations as a tree, newest first: switching back and changing Mycroft from there starts a branch. Tap
 * twice to switch to one. */
function Generations({ generation }) {
	const call = useCall()
	const [armed, setArmed] = useState(null)
	const [all, setAll] = useState(false)
	if (!generation) return null
	const rows = graph(generation.history)
	const shown = all ? rows : rows.slice(0, 5)
	const lanes = Math.max(1, ...shown.map((row) => Math.max(row.before.length, row.after.length, row.lane + 1)))
	const use = (number) => {
		if (armed !== number) return setArmed(number)
		setArmed(null)
		haptic(call, 'medium')
		call('generation.rollback', { generation: number })
	}
	return html`<div class="card list-card">
		${shown.map((row) => {
			const { record } = row
			return html`<div class="gen-row">
			<${GraphCell} row=${row} lanes=${lanes} active=${generation.active} />
			<span class="index">${pad(record.generation)}</span>
			<span class="grow"><span class="block">${record.note}</span><span class="faint mono tiny">${ago(record.createdAt)}</span></span>
			${record.generation === generation.active
				? html`<${Tag} tone="soft">Active<//>`
				: html`<button class=${`button small glass ${armed === record.generation ? 'prominent' : ''}`} onClick=${() => use(record.generation)}>
						${armed === record.generation ? 'Switch?' : record.generation === generation.lastGood ? 'Last good' : 'Use'}</button>`}
			</div>`
		})}
		${shown.length < rows.length && html`<button class="more inline" onClick=${() => setAll(true)}>Show ${rows.length - shown.length} older</button>`}
		<p class="faint small">Shake the phone to recover from a broken generation.</p>
	</div>`
}

function Machines({ machines }) {
	const call = useCall()
	const { go } = useNavigation()
	const [status, setStatus] = useState({})
	const [menu, setMenu] = useState(null)
	const names = machines.map((m) => m.name).join(',')
	useEffect(() => {
		setStatus({})
		call('machines.check').then(setStatus).catch(() => {})
	}, [names])
	return html`<div class="card list-card">
		${machines.map((machine) => html`<div class="machine-row" onClick=${() => setMenu(menu === machine.name ? null : machine.name)}>
			<div class="row between">
				<span><span class="mono strong block">${machine.name}</span>
					<span class="faint mono tiny">${machine.os === 'macos' ? 'macOS' : machine.os === 'linux' ? 'Linux' : machine.os} · ${machine.arch} · ${machine.addresses?.[0] ?? '?'}:${machine.port}</span></span>
				${status[machine.name] === 'online'
					? html`<${Tag} tone="success">Online<//>`
					: status[machine.name] ? html`<${Tag} tone="danger">Offline<//>` : html`<${Spinner} />`}
			</div>
			${status[machine.name] && status[machine.name] !== 'online' && html`<p class="danger mono tiny">${status[machine.name]}</p>`}
			${menu === machine.name && html`<button class="button small glass danger" onClick=${() => call('machines.forget', { name: machine.name })}>Forget ${machine.name}</button>`}
		</div>`)}
		${!machines.length && html`<p class="muted small">Pair a Mac or a Linux machine to give Mycroft a shell, files, long jobs and desktop control.</p>`}
		<button class="button glass prominent wide" aria-label="Add machine" onClick=${() => go('#/pair')}><${Icon} name="machine" size=${16} /> Add machine</button>
	</div>`
}

function About() {
	const { go } = useNavigation()
	return html`<button class="card row between link-row" onClick=${() => go('#/notices')}>
		<span class="mono small">Open source notices</span><${Icon} name="chevron" size=${14} />
	</button>`
}

export function Notices() {
	const call = useCall()
	const [text, setText] = useState('')
	useEffect(() => { call('notices.thirdParty').then(setText) }, [])
	return html`<${Page} title="Notices"><pre class="notices">${text}</pre><//>`
}
