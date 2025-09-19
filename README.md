## Godot Stencil-based Outline CompositorEffect

This is a CompositorEffect for Godot 4.5 that uses the stencil buffer to create
on-screen outlines. It uses the jump-flood algorithm described by @bgolus in
his well-written article about [making very wide
outlines](https://bgolus.medium.com/the-quest-for-very-wide-outlines-ba82ed442cd9).
I did not implement any of the anti-aliasing described in the article, but
would happily merge anyone adding them.

https://github.com/user-attachments/assets/53d011d8-d8bb-43d7-8d70-73cf72c827f5

### !!! Important Note !!!
When running this CompositorEffect in an embedded game panel (floating or
docked), if you resize the window, the CompositorEffect may hit some asserts
because the Editor is freeing the texture buffers while the CompositorEffect is
running.  This **does not** happen in a non-embedded instance of the game, so
I'm not going to write a pile of code to work around it.

### Details/Setup
For any mesh you want to be outlined, you need its material to write a value to the stencil buffer:

<img width="289" height="230" alt="Screenshot 2025-09-19 at 11 22 53 AM" src="https://github.com/user-attachments/assets/ba6c5bd2-da84-4558-b883-a8c12d874b63" />

You need to add the CompositorEffect to the Camera3D, and configure it.  Note:
depending on the material used to write to the stencil buffer, you may need to
change the `Effect Callback Time`:

<img width="309" height="751" alt="Screenshot 2025-09-19 at 11 24 06 AM" src="https://github.com/user-attachments/assets/d780d9e9-395f-426c-9f70-44ffe779c07c" />

### License
MIT
