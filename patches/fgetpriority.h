/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Built-in port of fgetpriority (https://github.com/aerath-stuff/fgetpriority,
 * GPL-2.0, by xx and frknkrc44): stop an app from learning which other app
 * UIDs exist through getpriority/setpriority/ioprio_get/ioprio_set(PRIO_USER).
 *
 * The LKM hooks find_user() at runtime; here the four syscalls call
 * fgp_find_user() instead, which does the same filtering at source level.
 * For a seccomp-confined app (uid >= 10000) asking about another app's UID,
 * the user is reported as not existing. Root, system and the app's own UID
 * are untouched.
 */
#ifndef _LINUX_FGETPRIORITY_H
#define _LINUX_FGETPRIORITY_H

#include <linux/cred.h>
#include <linux/sched.h>
#include <linux/sched/user.h>
#include <linux/uidgid.h>
#include <linux/user_namespace.h>

#define FGP_MIN_APP_UID		10000
#define FGP_MIN_ISOLATED_UID	90000
#define FGP_PER_USER_RANGE	100000

static inline bool fgp_seccomp_on(void)
{
#ifdef TIF_SECCOMP
	return test_thread_flag(TIF_SECCOMP);
#elif defined(CONFIG_SECCOMP)
	return current->seccomp.mode != 0;
#else
	return false;
#endif
}

/* Isolated processes run in their own user namespace: map them to the host UID. */
static inline int fgp_isolated_to_host(int id)
{
	struct user_namespace *ns = current_user_ns();

	if (ns && ns != &init_user_ns) {
		kuid_t host = make_kuid(ns, 0);

		if (uid_valid(host))
			id = (int)from_kuid(&init_user_ns, host);
	}
	return id;
}

static inline bool fgp_should_hide(kuid_t kuid)
{
	int who = (int)__kuid_val(kuid);
	int cuid = (int)__kuid_val(current_uid());

	if (likely(!fgp_seccomp_on()))
		return false;
	if (cuid < FGP_MIN_APP_UID || who < FGP_MIN_APP_UID)
		return false;

	if (cuid >= FGP_PER_USER_RANGE)
		cuid %= FGP_PER_USER_RANGE;
	if (cuid >= FGP_MIN_ISOLATED_UID)
		cuid = fgp_isolated_to_host(cuid);

	if (who >= FGP_MIN_ISOLATED_UID)
		who = fgp_isolated_to_host(who);
	if (who >= FGP_PER_USER_RANGE)
		who %= FGP_PER_USER_RANGE;

	return cuid != who;
}

/* Do the lookup either way so both outcomes cost the same. */
static inline struct user_struct *fgp_find_user(kuid_t uid)
{
	bool hide = fgp_should_hide(uid);
	struct user_struct *user = find_user(uid);

	if (hide && user) {
		free_uid(user);
		user = NULL;
	}
	return user;
}

#endif /* _LINUX_FGETPRIORITY_H */
