#ifndef LUA_THREAD_POOL_H_
#define LUA_THREAD_POOL_H_

#include <lua.h>

struct thread_entry;
struct lua_thread_pool;

typedef void (*lua_thread_finish_t) (struct thread_entry *thread, int ret);
typedef void (*lua_thread_error_t) (struct thread_entry *thread, int ret, const char *msg);

struct thread_entry {
	lua_State *lua_state;
	gint thread_index;
	gpointer cd;

	/* function to handle result of called method, can be NULL */
	lua_thread_finish_t finish_callback;

	/* function to log result, i.e. if you want to modify error logging message or somehow process this state, can be NUL */
	lua_thread_error_t error_callback;
	struct rspamd_task *task;
	struct rspamd_config *cfg;
};

struct lua_callback_state {
	lua_State *L;
	struct thread_entry *my_thread;
	struct thread_entry *previous_thread;
	struct lua_thread_pool *thread_pool;
};

/**
 * Allocates new thread pool on state L. Pre-creates number of lua-threads to use later on
 *
 * @param L
 * @return
 */
struct lua_thread_pool *
lua_thread_pool_new (lua_State * L);

/**
 * Destroys the pool
 * @param pool
 */
void
lua_thread_pool_free (struct lua_thread_pool *pool);

/**
 * Extracts a thread from the list of available ones.
 * It immediately becames running one and should be used to run a Lua script/function straight away.
 * as soon as the code is finished, it should be either returned into list of available threads by
 * calling lua_thread_pool_return() or terminated by calling lua_thread_pool_terminate_entry()
 * if the code finished with error.
 *
 * If the code performed YIELD, the thread is still running and it's live should be controlled by the callee
 *
 * @param pool
 * @return
 */
struct thread_entry *
lua_thread_pool_get(struct lua_thread_pool *pool);

/**
 * Return thread into the list of available ones. It can't be done with yielded or dead threads.
 *
 * @param pool
 * @param thread_entry
 */
void
lua_thread_pool_return(struct lua_thread_pool *pool, struct thread_entry *thread_entry);

/**
 * Currently running thread. Typically needed in yielding point - to fill-up continuation.
 *
 * @param pool
 * @return
 */
struct thread_entry *
lua_thread_pool_get_running_entry (struct lua_thread_pool *pool);

/**
 * Updates currently running thread
 *
 * @param pool
 * @param thread_entry
 */
void
lua_thread_pool_set_running_entry (struct lua_thread_pool *pool, struct thread_entry *thread_entry);

/**
 * Prevents yielded thread to be used for callback execution. lua_thread_pool_restore_callback() should be called afterwards.
 *
 * @param pool
 * @param cbs
 */
void
lua_thread_pool_prepare_callback (struct lua_thread_pool *pool, struct lua_callback_state *cbs);

/**
 * Restores state after lua_thread_pool_prepare_callback () usage
 *
 * @param cbs
 */
void
lua_thread_pool_restore_callback (struct lua_callback_state *cbs);


/**
 * Acts like lua_call but the tread is able to suspend execution.
 * As soon as the call is over, call either thread_entry::finish_callback or thread_entry::error_callback.
 *
 * @param thread_entry
 * @param narg
 */
void
lua_thread_call (struct thread_entry *thread_entry, int narg);

#endif /* LUA_THREAD_POOL_H_ */

