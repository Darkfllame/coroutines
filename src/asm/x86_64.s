global coro_resume
global coro_yield
global coro_always_yield

section .text

struc RawCoroutine
    .top: resq 1
    .bottom: resq 1
    .rsp: resq 1
    .rbp: resq 1
    .rip: resq 1
    .rbx: resq 1
    .r12: resq 1
    .r13: resq 1
    .r14: resq 1
    .r15: resq 1
endstruc

struc ResumeStack
    .rbx: resq 1
    .r12: resq 1
    .r13: resq 1
    .r14: resq 1
    .r15: resq 1
    alignb 16
endstruc

coro_resume: ; (rdi: *RawCoroutine)
    push rbp
    mov rbp, rsp
    sub rsp, ResumeStack_size

    mov qword [rsp + ResumeStack.rbx], rbx
    mov qword [rsp + ResumeStack.r12], r12
    mov qword [rsp + ResumeStack.r13], r13
    mov qword [rsp + ResumeStack.r14], r14
    mov qword [rsp + ResumeStack.r15], r15

    ; rsp <=> rdi.rsp
    xchg rsp, qword [rdi + RawCoroutine.rsp]
    ; rbp <=> rdi.rbp
    xchg rbp, qword [rdi + RawCoroutine.rbp]
    %ifdef WINDOWS
    mov rax, qword [rdi + RawCoroutine.bottom]
    xchg qword gs:[0x8], rax
    mov qword [rdi + RawCoroutine.bottom], rax

    mov rax, qword [rdi + RawCoroutine.top]
    xchg qword gs:[0x10], rax
    mov qword [rdi + RawCoroutine.top], rax
    %endif

    mov rax, qword [rdi + RawCoroutine.rip]
    
    ; and rsp, 0xFFFFFFFFFFFFFFF0
    jmp rax

coro_always_yield:
    mov qword [rdi + RawCoroutine.rip], coro_yield.swap_stack
    jmp coro_yield.swap_stack

coro_yield: ; (rdi: *RawCoroutine)
    mov qword [rdi + RawCoroutine.rip], .return
    
    .swap_stack:
    ; rsp <=> rdi.rsp
    xchg rsp, qword [rdi + RawCoroutine.rsp]
    ; rbp <=> rdi.rbp
    xchg rbp, qword [rdi + RawCoroutine.rbp]
    %ifdef WINDOWS
    mov rax, qword [rdi + RawCoroutine.bottom]
    xchg qword gs:[0x8], rax
    mov qword [rdi + RawCoroutine.bottom], rax
    
    mov rax, qword [rdi + RawCoroutine.top]
    xchg qword gs:[0x10], rax
    mov qword [rdi + RawCoroutine.top], rax
    %endif

    mov rbx, qword [rsp + ResumeStack.rbx]
    mov r12, qword [rsp + ResumeStack.r12]
    mov r13, qword [rsp + ResumeStack.r13]
    mov r14, qword [rsp + ResumeStack.r14]
    mov r15, qword [rsp + ResumeStack.r15]

    add rsp, ResumeStack_size
    pop rbp
    .return:
    ret