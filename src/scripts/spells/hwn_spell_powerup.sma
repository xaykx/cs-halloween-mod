#pragma semicolon 1

#include <amxmodx>
#include <fakemeta>
#include <hamsandwich>
#include <cstrike>
#include <fun>
#include <xs>

#include <hwn>
#include <hwn_utils>

#define PLUGIN "[Hwn] Power Up Spell"
#define AUTHOR "Hedgehog Fog"

#if !defined MAX_PLAYERS
    #define MAX_PLAYERS 32
#endif

#define JUMP_SPEED 320.0
#define JUMP_DELAY 0.175
#define JUMP_EFFECT_BRIGHTNESS 255
#define JUMP_EFFECT_LIFETIME 5
#define SPEED_BOOST 2.0
#define WEAPON_SPEED_BOOST 1.25

const Float:EffectTime = 10.0;
const EffectRadius = 48;
new const EffectColor[3] = {HWN_COLOR_PRIMARY};

new const g_szSndDetonate[] = "hwn/spells/spell_powerup.wav";
new const g_szSndJump[] = "hwn/spells/spell_powerup_jump.wav";

new g_sprTrail;

new g_playerSpellEffectFlag = 0;
new Float:g_playerLastJump[MAX_PLAYERS + 1] = { 0.0, ... };

new g_hWofSpell;

new g_maxPlayers;

public plugin_precache()
{
    g_sprTrail = precache_model("sprites/zbeam2.spr");
    precache_sound(g_szSndDetonate);
    precache_sound(g_szSndJump);

    Hwn_Spell_Register(
        "Power Up",
        (
            Hwn_SpellFlag_Applicable
                | Hwn_SpellFlag_Ability
                | Hwn_SpellFlag_Damage
                | Hwn_SpellFlag_Heal
                | Hwn_SpellFlag_Rare
        ),
        "Cast"
    );

    g_hWofSpell = Hwn_Wof_Spell_Register("Power Up", "Invoke", "Revoke");
}

public plugin_cfg()
{
    server_cmd("sv_maxspeed 9999");
}

public plugin_init()
{
    register_plugin(PLUGIN, HWN_VERSION, AUTHOR);

    RegisterHam(Ham_Player_Jump, "player", "OnPlayerJump", .Post = 1);
    RegisterHam(Ham_Item_PreFrame, "player", "OnPlayerItemPreFrame", .Post = 1);
    RegisterHam(Ham_TakeDamage, "player", "OnPlayerTakeDamage", .Post = 0);
    RegisterHam(Ham_Killed, "player", "Revoke", .Post = 1);

    for (new i = CSW_NONE + 1; i <= CSW_LAST_WEAPON; ++i) {
        if ((1 << i) & ~(CSW_ALL_GUNS | (1 << CSW_KNIFE))) {
            continue;
        }

        new szWeaponName[32];
        get_weaponname(i, szWeaponName, charsmax(szWeaponName));

        RegisterHam(Ham_Weapon_PrimaryAttack, szWeaponName, "OnWeaponAttack", .Post = 1);
        RegisterHam(Ham_Weapon_SecondaryAttack, szWeaponName, "OnWeaponAttack", .Post = 1);
    }

    g_maxPlayers = get_maxplayers();
}


/*--------------------------------[ Forwards ]--------------------------------*/

#if AMXX_VERSION_NUM < 183
    public client_disconnect(id)
#else
    public client_disconnected(id)
#endif
{
    Revoke(id);
}

public Hwn_Gamemode_Fw_NewRound()
{
    for (new i = 1; i <= g_maxPlayers; ++i) {
        Revoke(i);
    }
}

/*--------------------------------[ Hooks ]--------------------------------*/

public OnWeaponAttack(ent)
{
    new id = UTIL_GetItemPlayer(ent);

    if (!is_user_alive(id)) {
        return HAM_IGNORED;
    }

    if (!GetSpellEffect(id)) {
        return HAM_IGNORED;
    }

    BoostWeaponShootSpeed(ent);

    return HAM_HANDLED;
}

public OnPlayerJump(id)
{
    if (!is_user_alive(id)) {
        return HAM_IGNORED;
    }

    if (!GetSpellEffect(id)) {
        return HAM_IGNORED;
    }

    new oldButton = pev(id, pev_oldbuttons);

    if (~oldButton & IN_JUMP) {
        ProcessPlayerJump(id);
    }

    return HAM_HANDLED;
}

public OnPlayerItemPreFrame(id)
{
    if (!is_user_alive(id)) {
        return HAM_IGNORED;
    }

    if (!GetSpellEffect(id)) {
        return HAM_IGNORED;
    }

    BoostPlayerSpeed(id);

    return HAM_HANDLED;
}

public OnPlayerTakeDamage(id, inflictor, attacker, Float:fDamage, damageBits)
{
    if (!is_user_alive(id)) {
        return HAM_IGNORED;
    }

    if (!GetSpellEffect(id)) {
        return HAM_IGNORED;
    }

    if (~damageBits & DMG_FALL) {
        return HAM_IGNORED;
    }

    SetHamParamFloat(4, 0.0);
    return HAM_OVERRIDE;
}

/*--------------------------------[ Methods ]--------------------------------*/

public Cast(id)
{
    if (!is_user_alive(id)) {
        return;
    }

    Invoke(id);

    if (Hwn_Wof_Effect_GetCurrentSpell() != g_hWofSpell) {
        set_task(EffectTime, "Revoke", id);
    }
}

public Invoke(id)
{
    Revoke(id);

    SetSpellEffect(id, true);
    Heal(id);
    JumpEffect(id);
    ExecuteHamB(Ham_Item_PreFrame, id);
    emit_sound(id, CHAN_STATIC , g_szSndDetonate, VOL_NORM, ATTN_NORM, 0, PITCH_NORM);
}

public Revoke(id)
{
    if (!GetSpellEffect(id)) {
        return;
    }

    SetSpellEffect(id, false);
    remove_task(id);

    if (is_user_connected(id)) {
        ExecuteHamB(Ham_Item_PreFrame, id);
    }
}

bool:GetSpellEffect(id)
{
    return !!(g_playerSpellEffectFlag & (1 << (id & 31)));
}

SetSpellEffect(id, bool:value)
{
    if (value) {
        g_playerSpellEffectFlag |= (1 << (id & 31));
    } else {
        g_playerSpellEffectFlag &= ~(1 << (id & 31));
    }
}

ProcessPlayerJump(id)
{
    new flags = pev(id, pev_flags);

    if (~flags & FL_ONGROUND) {
        if (get_gametime() - g_playerLastJump[id] < JUMP_DELAY) {
            return;
        }

        Jump(id);
    }

    JumpEffect(id);
    g_playerLastJump[id] = get_gametime();
}

Jump(id)
{
    static Float:fMaxSpeed;
    pev(id, pev_maxspeed, fMaxSpeed);

    static Float:vVelocity[3];
    GetMoveVector(id, vVelocity);
    xs_vec_mul_scalar(vVelocity, fMaxSpeed, vVelocity);
    vVelocity[2] = JUMP_SPEED;
    
    set_pev(id, pev_velocity, vVelocity);
    set_pev(id, pev_gaitsequence, 6);

    emit_sound(id, CHAN_STATIC , g_szSndJump, VOL_NORM, ATTN_NORM, 0, PITCH_NORM);
}

public BoostWeaponShootSpeed(ent)
{
    new Float:fMultiplier =  1.0 / WEAPON_SPEED_BOOST;

    new Float:fNextPrimaryAttack = UTIL_GetNextPrimaryAttack(ent);
    new Float:fNextSecondaryAttack = UTIL_GetNextSecondaryAttack(ent);

    UTIL_SetNextPrimaryAttack(ent, fNextPrimaryAttack * fMultiplier);
    UTIL_SetNextSecondaryAttack(ent, fNextSecondaryAttack * fMultiplier);
}

BoostPlayerSpeed(id)
{
    new Float:fMaxSpeed = get_user_maxspeed(id);
    set_user_maxspeed(id, fMaxSpeed * SPEED_BOOST);
}

JumpEffect(id)
{
    static Float:vOrigin[3];
    pev(id, pev_origin, vOrigin);

    static Float:vMins[3];
    pev(id, pev_mins, vMins);

    vOrigin[2] += vMins[2] + 1.0;

    UTIL_Message_BeamDisk(
        vOrigin,
        float(EffectRadius) * (10 / JUMP_EFFECT_LIFETIME),
        .modelIndex = g_sprTrail,
        .color = EffectColor,
        .brightness = JUMP_EFFECT_BRIGHTNESS,
        .speed = 0,
        .noise = 0,
        .lifeTime = JUMP_EFFECT_LIFETIME,
        .width = 0
    );
}

GetMoveVector(id, Float:vOut[3])
{
    xs_vec_copy(Float:{0.0, 0.0, 0.0}, vOut);

    new button = pev(id, pev_button);

    static Float:vAngles[3];
    pev(id, pev_angles, vAngles);

    static Float:vDirectionForward[3];
    angle_vector(vAngles, ANGLEVECTOR_FORWARD, vDirectionForward);

    static Float:vDirectionRight[3];
    angle_vector(vAngles, ANGLEVECTOR_RIGHT, vDirectionRight);

    if (button & IN_FORWARD) {
        xs_vec_add(vOut, vDirectionForward, vOut);
    }

    if (button & IN_BACK) {
        xs_vec_sub(vOut, vDirectionForward, vOut);
    }
    
    if (button & IN_MOVERIGHT) {
        xs_vec_add(vOut, vDirectionRight, vOut);
    }

    if (button & IN_MOVELEFT) {
        xs_vec_sub(vOut, vDirectionRight, vOut);
    }

    vOut[2] = 0.0;

    xs_vec_normalize(vOut, vOut);
}

Heal(id)
{
    new Float:fHealth;
    pev(id, pev_health, fHealth);

    if (fHealth < 100.0) {
        set_pev(id, pev_health, 100.0);
    }
}
