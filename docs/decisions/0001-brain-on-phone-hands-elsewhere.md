# 0001 · Brain on the phone, hands elsewhere

**Status:** accepted

The agent loop, durable state, credentials and agent source live on the iPhone. Other machines only execute tools.

**Why:** This is the property that makes Mario's pim work: no VPS to babysit, the phone is always with you, and the state and credentials never leave it. iOS can't run a shell, so on iOS the hands are *always* remote. On Android that's optional.

**Consequence:** Anything that must outlive the phone being offline (builds, long jobs) has to be owned by `hands`, not by an SSH session the phone holds open. See 0005.
