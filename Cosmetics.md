Cosmetics
SetBodyGroup - fired on both the prop and the teamflag
tf_glow - controlled by a glow outline for ALL flags and props (not templated for bluflag or bluflag_prop)

OnPickupEvent
-> attach prop (SetParentAttachment) to the !activator (player)
-> Enable prop/set to render. This will automatically show its glow.
-> flag automatically stops rendering, so managing the glow is not a problem

OnDropevent
-> attach prop (SetParentAttachment) to the blu_lmm_target (flag follower)
-> Disable prop/set not render

glows start enabled, flag prop start disabled

Me: Further customizability on these glows: add to our event-driven logic. set tf_glows to Enable all in a 'vscript flagspawner template' for a configurable duration on our events:
on pinata -> 5 damage chunks + (add to readme: optional SFX For the remainder 6th piece ForceReturn)
    On damage chunk -> same thing 
    On flagspawner used -> same thing
    On pickup 
    On drop
    

It seems like we cannot spawn a new glow for a template'd flag without bugs? like a tf_glow for bluflag_prop_glow001 that we control like you are saying...vscript does this fine tho?
 Gemini: Yes, VScript does this perfectly, and it is the only way to do it without bugs.

Here is the technical reality of why you might have thought it was "buggy" before, and how v9 fixes it:

The "Bug" (Hammer-only)
If you rely purely on Hammer's point_template, the tf_glow creates a hard link to the prop name (e.g., bluflag_prop&001).

Problem: When a player picks it up, you can't tell the glow to "switch to the player" using only Hammer I/O easily, because you don't know the player's name.

Result: The glow sits on the floor (or vanishes) while the player runs away unglowed.

The Fix (VScript)
VScript bypasses the naming problem entirely by using Handles.

We spawn the template.

We capture the specific glow entity handle for that specific flag.

On Pickup: We tell that specific glow handle: SetTarget -> !activator (The Player).

On Drop: We tell that specific glow handle: SetTarget -> bluflag_prop (The Meter).

This allows us to recycle the same single tf_glow entity for both the floor meter and the player model.









Glow Management on flags:
    we DONT WANT TO enable/disable glows on specific flags (using suffix management we can)
    we CAN set the prop to not render if the flag value is low

    Rules for enforcement of the action:
        Number of unique flags found per team (bluflag*00x) > 25
        
    Action: Disable Prop


Idea for implementation: Use the suffix to disable props for flags above 25 in name? It only works if the entity maker logic resets to 0 in its counting + pd auto killing the flag entities
I will test this out to see how high I can get the suffix


Balance/Logic Idea:

Limited flag pool so damage chunks limit the ability for them to spawn flags

Another idea to implement: OnReturn -> We want the flag you get to be ADDED to your budget so if you have generated 100+ points of flags ->  EVERYONE gets 100+ point flags! We clamp the bonus at 99 (so you can get the full 100). 
    We want to limit the total number of flags you can spawn to be like (25) so if you do a lot of pinata and chunks and 'separate the flag value' , you end up chunking your next flag into a heftier sum when it returns each time. 