// Conversation mode in a thread: the dock that takes the composer's place while the user talks with Mycroft. The
// conversation itself runs in the app (the `talk` events and ops), so it goes on with the screen locked; this shows it.
//
// The orb follows whoever is speaking. A tap on it stops Mycroft speaking, or sends what the user said without waiting
// for the pause. The mic button mutes the user; ✕ ends the conversation and leaves the run working.

import { html } from '/lib/preact.js'
import { useData, useCall, Icon, Label, Spinner, haptic } from '../lib.js'

/** The conversation, while it is on in thread `id` (null: a new thread's draft, until its first words create it). */
export function useTalk(id) {
	const talk = useData((d) => d.talk)
	if (!talk || talk.phase === 'off') return null
	return talk.thread === id || (id == null && talk.thread == null) ? talk : null
}

const phases = {
	starting: 'Starting',
	listening: 'Listening',
	hearing: 'Hearing you',
	working: 'Working',
	speaking: 'Mycroft',
}

/** `above` sits over the dock (the run's status), as over the composer. */
export function TalkDock({ talk, above }) {
	const call = useCall()
	const act = (op, args, style) => {
		haptic(call, style)
		call(op, args).catch(() => {})
	}
	const caption = talk.phase === 'speaking' ? talk.said
		: talk.heard ? talk.heard
		: talk.phase === 'working' ? talk.status
		: talk.phase === 'starting' ? (talk.voiceReady ? 'Starting the microphone…' : 'Waking the voice…')
		: talk.muted ? 'Muted' : 'Go ahead'
	const orbLabel = talk.phase === 'speaking' ? 'Stop speaking' : talk.heard ? 'Send now' : 'Conversation'
	return html`<div class="composer talk">
		${above}
		<div class="talk-dock glass">
			<div class="talk-caption">
				<div class="row gap">
					${(talk.phase === 'working' || talk.phase === 'starting') && html`<${Spinner} />`}
					<${Label} tone=${talk.phase === 'hearing' ? 'ink' : 'soft'} size=${10}>${phases[talk.phase] ?? talk.phase}<//>
					${talk.phase === 'speaking' && talk.cutIn !== 'words' && html`<span class="faint tiny mono">· ${talk.cutIn === 'stop' ? 'say “stop” or tap' : 'tap'} to cut in</span>`}
				</div>
				<p class=${`talk-words ${talk.heard ? 'ink' : 'muted'}`}>${caption}</p>
				${talk.error && html`<p class="danger small mono">${talk.error}</p>`}
			</div>
			<div class="talk-controls">
				<button class=${`icon-button glass ${talk.muted ? 'danger' : ''}`} aria-label=${talk.muted ? 'Unmute' : 'Mute'}
					onClick=${() => act('talk.mute', { on: !talk.muted })}>
					<${Icon} name=${talk.muted ? 'mic-off' : 'mic'} />
				</button>
				<button class=${`orb ${talk.phase}`} aria-label=${orbLabel} style=${`--level:${talk.level ?? 0}`}
					onClick=${() => act('talk.tap', {}, 'medium')}>
					<span class="orb-core"></span>
				</button>
				<button class="icon-button glass" aria-label="End conversation" onClick=${() => act('talk.end', {}, 'medium')}>
					<${Icon} name="close" />
				</button>
			</div>
		</div>
	</div>`
}
