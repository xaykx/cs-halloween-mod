#pragma semicolon 1

#include <amxmodx>
#include <engine>
#include <fakemeta>
#include <hamsandwich>
#include <xs>

#tryinclude <reapi>

#if defined _reapi_included
    #define ROUND_CONTINUE HC_CONTINUE
    #define ROUND_SUPERCEDE HC_SUPERCEDE
    #define WINSTATUS_TERRORIST WINSTATUS_TERRORISTS
    #define WINSTATUS_CT WINSTATUS_CTS
#else
    #include <roundcontrol>
#endif

#include <hwn>
#include <hwn_utils>


#define PLUGIN "[Hwn] Gamemode"
#define AUTHOR "Hedgehog Fog"

#define TASKID_ROUNDTIME_EXPIRE 1

#define TASKID_SUM_RESPAWN_PLAYER 1000
#define TASKID_SUM_SPAWN_PROTECTION 2000

#define MIN_EVENT_POINTS 8
#define MAX_EVENT_POINTS 32

#define SPAWN_RANGE 192.0

enum GameState
{
    GameState_NewRound,
    GameState_RoundStarted,
    GameState_RoundEnd
};

new g_fwResult;
new g_fwNewRound;
new g_fwRoundStart;
new g_fwRoundEnd;
new g_fwRoundExpired;

new g_fmFwSpawn;

new g_cvarRespawnTime;
new g_cvarSpawnProtectionTime;
new g_cvarNewRoundDelay;

new GameState:g_gamestate;

new g_gamemode = -1;
new g_defaultGamemode = -1;

new Trie:g_gamemodeIndex;
new Array:g_gamemodeName;
new Array:g_gamemodeFlags;
new Array:g_gamemodePluginID;
new g_gamemodeCount = 0;

new Float:g_fRoundStartTime;

new g_playerFirstSpawnFlag = 0;
new Array:g_tSpawnPoints;
new Array:g_ctSpawnPoints;
new Float:g_eventPoints[MAX_EVENT_POINTS][3];

new g_maxPlayers;

static g_szEquipmentMenuTitle[32];

public plugin_precache()
{
    register_dictionary("hwn.txt");
    format(g_szEquipmentMenuTitle, charsmax(g_szEquipmentMenuTitle), "%L", LANG_SERVER, "HWN_EQUIPMENT_MENU_TITLE");

    g_fmFwSpawn = register_forward(FM_Spawn, "OnSpawn", 1);

    g_tSpawnPoints = ArrayCreate(3);
    g_ctSpawnPoints = ArrayCreate(3);
}

public plugin_init()
{
    register_plugin(PLUGIN, HWN_VERSION, AUTHOR);

    if (g_gamemode < 0 && g_defaultGamemode >= 0) {
        SetGamemode(g_defaultGamemode);
    }

    #if defined _reapi_included
        RegisterHookChain(RG_CSGameRules_CheckWinConditions, "OnCheckWinConditions");
    #else
        RegisterControl(RC_CheckWinConditions, "OnCheckWinConditions");
    #endif

    RegisterHam(Ham_Spawn, "player", "OnPlayerSpawn", .Post = 1);
    RegisterHam(Ham_Killed, "player", "OnPlayerKilled", .Post = 1);

    register_event("HLTV", "OnNewRound", "a", "1=0", "2=0");
    register_logevent("OnRoundStart", 2, "1=Round_Start");
    register_logevent("OnRoundEnd", 2, "1=Round_End");
    register_event("TextMsg", "OnRoundEnd", "a", "2=#Game_will_restart_in");

    register_message(get_user_msgid("ClCorpse"), "OnMessage_ClCorpse");
    register_message(get_user_msgid("RoundTime"), "OnMessage_RoundTime");

    register_clcmd("joinclass", "OnClCmd_JoinClass");
    register_clcmd("menuselect", "OnClCmd_JoinClass");

    g_maxPlayers = get_maxplayers();

    g_cvarRespawnTime = register_cvar("hwn_gamemode_respawn_time", "5.0");
    g_cvarSpawnProtectionTime = register_cvar("hwn_gamemode_spawn_protection_time", "3.0");
    g_cvarNewRoundDelay = register_cvar("hwn_gamemode_new_round_delay", "10.0");

    g_fwNewRound = CreateMultiForward("Hwn_Gamemode_Fw_NewRound", ET_IGNORE);
    g_fwRoundStart = CreateMultiForward("Hwn_Gamemode_Fw_RoundStart", ET_IGNORE);
    g_fwRoundEnd = CreateMultiForward("Hwn_Gamemode_Fw_RoundEnd", ET_IGNORE);
    g_fwRoundExpired = CreateMultiForward("Hwn_Gamemode_Fw_RoundExpired", ET_IGNORE);

    register_forward(FM_SetModel, "OnSetModel");

    unregister_forward(FM_Spawn, g_fmFwSpawn, 1);
}

public OnSpawn(ent)
{
    if (!pev_valid(ent)) {
        return;
    }

    new szClassname[32];
    pev(ent, pev_classname, szClassname, charsmax(szClassname));

    new Float:vOrigin[3];
    pev(ent, pev_origin, vOrigin);

    if (equal(szClassname, "info_player_start")) {
        ArrayPushArray(g_ctSpawnPoints, vOrigin);
    } else if(equal(szClassname, "info_player_deathmatch")) {
        ArrayPushArray(g_tSpawnPoints, vOrigin);
    }
}

public plugin_natives()
{
    register_library("hwn");
    register_native("Hwn_Gamemode_Register", "Native_Register");
    register_native("Hwn_Gamemode_Activate", "Native_Activate");
    register_native("Hwn_Gamemode_DispatchWin", "Native_DispatchWin");
    register_native("Hwn_Gamemode_GetCurrent", "Native_GetCurrent");
    register_native("Hwn_Gamemode_GetHandler", "Native_GetHandler");
    register_native("Hwn_Gamemode_IsPlayerOnSpawn", "Native_IsPlayerOnSpawn");
    register_native("Hwn_Gamemode_FindEventPoint", "Native_FindEventPoint");
    register_native("Hwn_Gamemode_GetRoundTime", "Native_GetRoundTime");
    register_native("Hwn_Gamemode_SetRoundTime", "Native_SetRoundTime");
    register_native("Hwn_Gamemode_GetRoundTimeLeft", "Native_GetRoundTimeLeft");
    register_native("Hwn_Gamemode_IsRoundStarted", "Native_IsRoundStarted");
    register_native("Hwn_Gamemode_GetFlags", "Native_GetFlags");
}

public plugin_end()
{
    if (!g_gamemodeCount) {
        TrieDestroy(g_gamemodeIndex);
        ArrayDestroy(g_gamemodeName);
        ArrayDestroy(g_gamemodeFlags);
        ArrayDestroy(g_gamemodePluginID);
    }

    ArrayDestroy(g_tSpawnPoints);
    ArrayDestroy(g_ctSpawnPoints);
}

public client_connect(id)
{
    g_playerFirstSpawnFlag |= (1 << (id & 31));
}

#if AMXX_VERSION_NUM < 183
    public client_disconnect(id)
#else
    public client_disconnected(id)
#endif
{
    remove_task(id+TASKID_SUM_SPAWN_PROTECTION);
}

/*--------------------------------[ Natives ]--------------------------------*/

public Native_Register(pluginID, argc)
{
    new szName[32];
    get_string(1, szName, charsmax(szName));

    new Hwn_GamemodeFlags:flags = Hwn_GamemodeFlags:get_param(2);

    if (!g_gamemodeCount) {
        g_gamemodeIndex = TrieCreate();
        g_gamemodeName = ArrayCreate(32);
        g_gamemodeFlags = ArrayCreate();
        g_gamemodePluginID = ArrayCreate();
    }

    new index = g_gamemodeCount;
    TrieSetCell(g_gamemodeIndex, szName, index);
    ArrayPushString(g_gamemodeName, szName);
    ArrayPushCell(g_gamemodeFlags, flags);
    ArrayPushCell(g_gamemodePluginID, pluginID);

    if ((flags & Hwn_GamemodeFlag_Default) && g_defaultGamemode < 0) {
        g_defaultGamemode = index;
    }

    g_gamemodeCount++;

    return index;
}

public bool:Native_Activate(pluginID, argc)
{
    new gamemode = GetGamemodeByPluginID(pluginID);
    if (gamemode < 0) {
        return false;
    }

    SetGamemode(gamemode);

    return true;
}

public Native_DispatchWin(pluginID, argc)
{
    if (!g_gamemodeCount) {
        return;
    }

    if (pluginID != ArrayGetCell(g_gamemodePluginID, g_gamemode)) {
        return;
    }

    new team = get_param(1);
    DispatchWin(team);
}

public Native_GetCurrent(pluginID, argc)
{
    return g_gamemode;
}

public Native_GetHandler(pluginID, argc)
{
    new szName[32];
    get_string(1, szName, charsmax(szName));

    new gamemode;
    if (TrieGetCell(g_gamemodeIndex, szName, gamemode)) {
        return gamemode;
    }

    return -1;
}

public Native_IsPlayerOnSpawn(pluginID, argc)
{
    new id = get_param(1);
    return IsPlayerOnSpawn(id);
}

public Native_FindEventPoint()
{
    new Float:vOrigin[3];
    new bool:result = FindEventPoint(vOrigin);

    set_array_f(1, vOrigin, sizeof(vOrigin));

    return result;
}

public Native_GetRoundTime(pluginID, argc)
{
    return GetRoundTime();
}

public Native_SetRoundTime(pluginID, argc)
{
    new time = get_param(1);
    SetRoundTime(time);
}

public Native_GetRoundTimeLeft(pluginID, argc)
{
    return GetRoundTimeLeft();
}

public bool:Native_IsRoundStarted(pluginID, argc)
{
    return g_gamestate > GameState_NewRound;
}

public Hwn_GamemodeFlags:Native_GetFlags(pluginID, argc)
{
    if (!g_gamemodeCount) {
        return Hwn_GamemodeFlag_None;
    }

    return ArrayGetCell(g_gamemodeFlags, g_gamemode);
}

/*--------------------------------[ Hooks ]--------------------------------*/

public OnNewRound()
{
    g_gamestate = GameState_NewRound;
    ExecuteForward(g_fwNewRound, g_fwResult);
}

public OnRoundStart()
{
    g_gamestate = GameState_RoundStarted;
    g_fRoundStartTime = get_gametime();

    UpdateRoundTime();

    ExecuteForward(g_fwRoundStart, g_fwResult);
}

public OnRoundEnd()
{
    g_gamestate = GameState_RoundEnd;

    remove_task(TASKID_ROUNDTIME_EXPIRE);

    for (new id = 1; id <= g_maxPlayers; ++id) {
        remove_task(id+TASKID_SUM_RESPAWN_PLAYER);
    }

    ExecuteForward(g_fwRoundEnd, g_fwResult);
}

public OnRoundTimeExpired()
{
    ExecuteForward(g_fwRoundExpired, g_fwResult);
}

public Hwn_PEquipment_Event_Changed(id)
{
    if (!g_gamemodeCount) {
        return;
    }

    new Hwn_GamemodeFlags:flags = ArrayGetCell(g_gamemodeFlags, g_gamemode);
    if (~flags & Hwn_GamemodeFlag_SpecialEquip) {
        return;
    }

    if (IsPlayerOnSpawn(id)) {
        Hwn_PEquipment_Equip(id);
    }
}

public OnClCmd_JoinClass(id)
{
    if (!g_gamemodeCount) {
        return PLUGIN_CONTINUE;
    }

    new Hwn_GamemodeFlags:flags = ArrayGetCell(g_gamemodeFlags, g_gamemode);
    if (~flags & Hwn_GamemodeFlag_RespawnPlayers) {
        return PLUGIN_CONTINUE;
    }

    #if defined _reapi_included
        new menu = get_member(id, m_iMenu);
        new joinState = get_member(id, m_iJoiningState);
    #else
        new menu = get_pdata_int(id, m_iMenu);
        new joinState = get_pdata_int(id, m_iJoiningState);
    #endif

    if (menu != MENU_CHOOSEAPPEARANCE) {
        return PLUGIN_CONTINUE;
    }

    new team = UTIL_GetPlayerTeam(id);
    new bool:inPlayableTeam = team == 1 || team == 2;

    if (joinState != JOIN_CHOOSEAPPEARANCE && (joinState || !inPlayableTeam)) {
        return PLUGIN_CONTINUE;
    }

    //ConnorMcLeod
    new command[11], arg1[32];
    read_argv(0, command, charsmax(command));
    read_argv(1, arg1, charsmax(arg1));
    engclient_cmd(id, command, arg1);

    ExecuteHam(Ham_Player_PreThink, id);

    if (!is_user_alive(id)) {
        SetRespawnTask(id);
    }

    return PLUGIN_HANDLED;
}

public OnMessage_ClCorpse()
{
    if (!g_gamemodeCount) {
        return PLUGIN_CONTINUE;
    }

    new Hwn_GamemodeFlags:flags = ArrayGetCell(g_gamemodeFlags, g_gamemode);
    if (flags & Hwn_GamemodeFlag_RespawnPlayers) {
        return PLUGIN_HANDLED;
    }

    return PLUGIN_CONTINUE;
}

public OnMessage_RoundTime()
{
    if (!g_gamemodeCount) {
        return PLUGIN_CONTINUE;
    }

    if (g_gamestate == GameState_NewRound) {
        return PLUGIN_CONTINUE;
    }

    set_msg_arg_int(1, ARG_SHORT, GetRoundTimeLeft());

    return PLUGIN_CONTINUE;
}

public OnPlayerSpawn(id)
{
    if (!is_user_alive(id)) {
        return;
    }

    if (!g_gamemodeCount) {
        return;
    }

    new Hwn_GamemodeFlags:flags = ArrayGetCell(g_gamemodeFlags, g_gamemode);
    if ((flags & Hwn_GamemodeFlag_SpecialEquip)) {
        Hwn_PEquipment_Equip(id);

        if (g_playerFirstSpawnFlag & (1 << (id & 31))) {
            Hwn_PEquipment_ShowMenu(id);
            g_playerFirstSpawnFlag &= ~(1 << (id & 31));
        }
    }

    if (flags & Hwn_GamemodeFlag_RespawnPlayers) {
        set_pev(id, pev_takedamage, DAMAGE_NO);
        remove_task(id+TASKID_SUM_SPAWN_PROTECTION);
        set_task(get_pcvar_float(g_cvarSpawnProtectionTime), "TaskDisableSpawnProtection", id+TASKID_SUM_SPAWN_PROTECTION);
    }
}

public OnPlayerKilled(id)
{
    if (!Hwn_Gamemode_IsPlayerOnSpawn(id)) {
        static Float:vOrigin[3];
        pev(id, pev_origin, vOrigin);

        if (!pev(id, pev_bInDuck)) {
            vOrigin[2] += 18.0;
        }

        AddEventPoint(vOrigin);
    }

    if (!g_gamemodeCount) {
        return;
    }

    if (g_gamemode < 0) {
        return;
    }

    new Hwn_GamemodeFlags:flags = ArrayGetCell(g_gamemodeFlags, g_gamemode);
    if ((flags & Hwn_GamemodeFlag_RespawnPlayers) && g_gamestate != GameState_RoundEnd) {
        SetRespawnTask(id);
    }
}

public OnSetModel(ent)
{
    if (!g_gamemodeCount) {
        return;
    }

    new Hwn_GamemodeFlags:flags = ArrayGetCell(g_gamemodeFlags, g_gamemode);
    if (~flags & Hwn_GamemodeFlag_SpecialEquip) {
        return;
    }

    static szClassname[32];
    pev(ent, pev_classname, szClassname, charsmax(szClassname));

    if (szClassname[9] == '^0' && szClassname[0] == 'w' && szClassname[6] == 'b') {
        dllfunc(DLLFunc_Think, ent);
    }
}

public MenuItem_ChangeEquipment(id)
{
    Hwn_PEquipment_ShowMenu(id);
}

public OnCheckWinConditions()
{
    if (!g_gamemodeCount) {
        return ROUND_CONTINUE;
    }

    if (g_gamemode < 0) {
        return ROUND_CONTINUE;
    }

    new Hwn_GamemodeFlags:flags = ArrayGetCell(g_gamemodeFlags, g_gamemode);
    if ((flags & Hwn_GamemodeFlag_RespawnPlayers) && IsTeamExtermination()) {
        return ROUND_SUPERCEDE;
    }

    return ROUND_CONTINUE;
}

/*--------------------------------[ Methods ]--------------------------------*/

SetGamemode(gamemode)
{
    g_gamemode = gamemode;
    new Hwn_GamemodeFlags:flags = ArrayGetCell(g_gamemodeFlags, g_gamemode);
    if (flags & Hwn_GamemodeFlag_SpecialEquip) {
        Hwn_Menu_AddItem(g_szEquipmentMenuTitle, "MenuItem_ChangeEquipment");
    }

    new szGamemodeName[32];
    ArrayGetString(g_gamemodeName, gamemode, szGamemodeName, charsmax(szGamemodeName));
    log_amx("[Hwn] Gamemode '%s' activated", szGamemodeName);
}

GetGamemodeByPluginID(pluginID)
{
    for (new gamemode = 0; gamemode < g_gamemodeCount; ++gamemode) {
        new gamemodePluginID = ArrayGetCell(g_gamemodePluginID, gamemode);

        if (pluginID == gamemodePluginID) {
            return gamemode;
        }
    }

    return -1;
}

RespawnPlayer(id)
{
    if (!is_user_connected(id)) {
        return;
    }

    if (is_user_alive(id)) {
        return;
    }

    new team = UTIL_GetPlayerTeam(id);

    if (team != 1 && team != 2) {
        return;
    }

    ExecuteHamB(Ham_CS_RoundRespawn, id);
}

bool:IsPlayerOnSpawn(id)
{
    static Float:vOrigin[3];
    pev(id, pev_origin, vOrigin);

    new team = UTIL_GetPlayerTeam(id);

    if (team < 1 || team > 2) {
        return false;
    }

    new Array:spawnPoints = team == 1 ? g_tSpawnPoints : g_ctSpawnPoints;
    new spawnPointsSize = ArraySize(spawnPoints);

    static Float:vSpawnOrigin[3];
    for (new i = 0; i < spawnPointsSize; ++i) {
        ArrayGetArray(spawnPoints, i, vSpawnOrigin);
        if (get_distance_f(vOrigin, vSpawnOrigin) <= SPAWN_RANGE) {
            return true;
        }
    }

    return false;
}

bool:FindEventPoint(Float:vOrigin[3])
{
    new size = 0;
    for (new i = 0; i < MAX_EVENT_POINTS; ++i) {
        if (xs_vec_len(g_eventPoints[i]) == 0.0) {
            break;
        }

        size++;
    }

    if (size < MIN_EVENT_POINTS) {
        return false;
    }

    xs_vec_copy(g_eventPoints[random(size)], vOrigin);

    return true;
}

AddEventPoint(const Float:vOrigin[3])
{
    new bool:isFull = xs_vec_len(g_eventPoints[MAX_EVENT_POINTS - 1]) > 0.0;

    for (new i = 0; i < MAX_EVENT_POINTS; ++i) {
        if (isFull) {
            if (!i) {
                continue;
            }

            xs_vec_copy(g_eventPoints[i], g_eventPoints[i - 1]);

            if (i < MAX_EVENT_POINTS - 1) {
                continue;
            }
        } else {
            if (xs_vec_len(g_eventPoints[i]) > 0.0) {
                continue;
            }
        }

        xs_vec_copy(vOrigin, g_eventPoints[i]);
        break;
    }
}

DispatchWin(team)
{
    if (g_gamestate == GameState_RoundEnd) {
        return;
    }

    if (team < 1 || team > 3) {
        return;
    }

    new Float:fDelay = get_pcvar_float(g_cvarNewRoundDelay);

    new any:winstatus = WINSTATUS_DRAW;
    if (team == 1) {
        winstatus = WINSTATUS_TERRORIST;
    } else if (team == 2) {
        winstatus = WINSTATUS_CT;
    }

    #if defined _reapi_included
        new ScenarioEventEndRound:event = ROUND_END_DRAW;
        if (team == 1) {
            event = ROUND_TERRORISTS_WIN;
        } else if (team == 2) {
            event = ROUND_CTS_WIN;
        }

        rg_round_end(fDelay, winstatus, event);
        rg_update_teamscores(team == 2 ? 1 : 0, team == 1 ? 1 : 0);
    #else
        RoundEndForceControl(winstatus, fDelay);
    #endif
}

bool:IsTeamExtermination()
{
    new bool:aliveT = false;
    new bool:aliveCT = false;

    for (new id = 1; id <= g_maxPlayers; ++id) {
        if (is_user_connected(id) && is_user_alive(id)) {
            new team = UTIL_GetPlayerTeam(id);

            if (team == 1) {
                aliveT = true;

                if (aliveCT) {
                    return false;
                }
            } else if (team == 2) {
                aliveCT = true;

                if (aliveT) {
                    return false;
                }
            }
        }
    }

    return true;
}

SetRespawnTask(id)
{
    set_task(get_pcvar_float(g_cvarRespawnTime), "TaskRespawnPlayer", id+TASKID_SUM_RESPAWN_PLAYER);
}

GetRoundTime()
{
    #if defined _reapi_included
        return get_member_game(m_iRoundTime);
    #else
        return get_pgame_int(m_iRoundTime);
    #endif
}

SetRoundTime(time)
{
    #if defined _reapi_included
        set_member_game(m_iRoundTime, time);
        set_member_game(m_fRoundStartTime, g_fRoundStartTime);
    #else
        set_pgame_int(m_iRoundTime, time);
        set_pgame_float(m_fRoundCount, g_fRoundStartTime);
    #endif

    UpdateRoundTime();
}

GetRoundTimeLeft()
{
    return floatround(g_fRoundStartTime + float(GetRoundTime()) - get_gametime());
}

UpdateRoundTime()
{
    new roundTimeLeft = GetRoundTimeLeft();

    UTIL_Message_RoundTime(0, roundTimeLeft);

    remove_task(TASKID_ROUNDTIME_EXPIRE);
    set_task(float(roundTimeLeft), "OnRoundTimeExpired", TASKID_ROUNDTIME_EXPIRE);
}

/*--------------------------------[ Tasks ]--------------------------------*/

public TaskRespawnPlayer(taskID)
{
    new id = taskID - TASKID_SUM_RESPAWN_PLAYER;

    RespawnPlayer(id);
}

public TaskDisableSpawnProtection(taskID)
{
    new id = taskID - TASKID_SUM_SPAWN_PROTECTION;

    set_pev(id, pev_takedamage, DAMAGE_AIM);
}
