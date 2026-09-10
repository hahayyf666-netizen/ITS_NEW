// R4B_EVENT_STATIC_BEGIN
// Generated mechanically from r4b_pre_butterfly_events.csv.
// Every audited event has a fixed phase, destination and source IDs.
// bf_bank/bf_vector_id remain the only dynamic context selectors.
if (bf_active) begin
    if (bf_cycle == 6'd3) begin
        signal_reg[0] <= $signed(dot_value_bank[bf_bank][0]) + $signed(dot_value_bank[bf_bank][1]);
        signal_vector[0] <= bf_vector_id;
    end
    if (bf_cycle == 6'd3) begin
        signal_reg[5] <= $signed(dot_value_bank[bf_bank][2]) + $signed(dot_value_bank[bf_bank][3]);
        signal_vector[5] <= bf_vector_id;
    end
    if (bf_cycle == 6'd3) begin
        signal_reg[10] <= $signed(dot_value_bank[bf_bank][2]) - $signed(dot_value_bank[bf_bank][3]);
        signal_vector[10] <= bf_vector_id;
    end
    if (bf_cycle == 6'd3) begin
        signal_reg[15] <= $signed(dot_value_bank[bf_bank][0]) - $signed(dot_value_bank[bf_bank][1]);
        signal_vector[15] <= bf_vector_id;
    end
    if (bf_cycle == 6'd4) begin
        signal_reg[1] <= $signed(signal_reg[0]) + $signed(dot_value_bank[bf_bank][4]);
        signal_vector[1] <= bf_vector_id;
    end
    if (bf_cycle == 6'd4) begin
        signal_reg[6] <= $signed(signal_reg[5]) + $signed(dot_value_bank[bf_bank][5]);
        signal_vector[6] <= bf_vector_id;
    end
    if (bf_cycle == 6'd4) begin
        signal_reg[11] <= $signed(signal_reg[10]) + $signed(dot_value_bank[bf_bank][6]);
        signal_vector[11] <= bf_vector_id;
    end
    if (bf_cycle == 6'd4) begin
        signal_reg[16] <= $signed(signal_reg[15]) + $signed(dot_value_bank[bf_bank][7]);
        signal_vector[16] <= bf_vector_id;
    end
    if (bf_cycle == 6'd4) begin
        signal_reg[20] <= $signed(signal_reg[15]) - $signed(dot_value_bank[bf_bank][7]);
        signal_vector[20] <= bf_vector_id;
    end
    if (bf_cycle == 6'd4) begin
        signal_reg[24] <= $signed(signal_reg[10]) - $signed(dot_value_bank[bf_bank][6]);
        signal_vector[24] <= bf_vector_id;
    end
    if (bf_cycle == 6'd4) begin
        signal_reg[28] <= $signed(signal_reg[5]) - $signed(dot_value_bank[bf_bank][5]);
        signal_vector[28] <= bf_vector_id;
    end
    if (bf_cycle == 6'd4) begin
        signal_reg[32] <= $signed(signal_reg[0]) - $signed(dot_value_bank[bf_bank][4]);
        signal_vector[32] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[2] <= $signed(signal_reg[1]) + $signed(dot_value_bank[bf_bank][8]);
        signal_vector[2] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[7] <= $signed(signal_reg[6]) + $signed(dot_value_bank[bf_bank][9]);
        signal_vector[7] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[12] <= $signed(signal_reg[11]) + $signed(dot_value_bank[bf_bank][10]);
        signal_vector[12] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[17] <= $signed(signal_reg[16]) + $signed(dot_value_bank[bf_bank][11]);
        signal_vector[17] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[21] <= $signed(signal_reg[20]) + $signed(dot_value_bank[bf_bank][12]);
        signal_vector[21] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[25] <= $signed(signal_reg[24]) + $signed(dot_value_bank[bf_bank][13]);
        signal_vector[25] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[29] <= $signed(signal_reg[28]) + $signed(dot_value_bank[bf_bank][14]);
        signal_vector[29] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[33] <= $signed(signal_reg[32]) + $signed(dot_value_bank[bf_bank][15]);
        signal_vector[33] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[36] <= $signed(signal_reg[32]) - $signed(dot_value_bank[bf_bank][15]);
        signal_vector[36] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[39] <= $signed(signal_reg[28]) - $signed(dot_value_bank[bf_bank][14]);
        signal_vector[39] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[42] <= $signed(signal_reg[24]) - $signed(dot_value_bank[bf_bank][13]);
        signal_vector[42] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[45] <= $signed(signal_reg[20]) - $signed(dot_value_bank[bf_bank][12]);
        signal_vector[45] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[48] <= $signed(signal_reg[16]) - $signed(dot_value_bank[bf_bank][11]);
        signal_vector[48] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[51] <= $signed(signal_reg[11]) - $signed(dot_value_bank[bf_bank][10]);
        signal_vector[51] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[54] <= $signed(signal_reg[6]) - $signed(dot_value_bank[bf_bank][9]);
        signal_vector[54] <= bf_vector_id;
    end
    if (bf_cycle == 6'd5) begin
        signal_reg[57] <= $signed(signal_reg[1]) - $signed(dot_value_bank[bf_bank][8]);
        signal_vector[57] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[3] <= $signed(signal_reg[2]) + $signed(dot_value_bank[bf_bank][16]);
        signal_vector[3] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[8] <= $signed(signal_reg[7]) + $signed(dot_value_bank[bf_bank][17]);
        signal_vector[8] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[13] <= $signed(signal_reg[12]) + $signed(dot_value_bank[bf_bank][18]);
        signal_vector[13] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[18] <= $signed(signal_reg[17]) + $signed(dot_value_bank[bf_bank][19]);
        signal_vector[18] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[22] <= $signed(signal_reg[21]) + $signed(dot_value_bank[bf_bank][20]);
        signal_vector[22] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[26] <= $signed(signal_reg[25]) + $signed(dot_value_bank[bf_bank][21]);
        signal_vector[26] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[30] <= $signed(signal_reg[29]) + $signed(dot_value_bank[bf_bank][22]);
        signal_vector[30] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[34] <= $signed(signal_reg[33]) + $signed(dot_value_bank[bf_bank][23]);
        signal_vector[34] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[76] <= $signed(signal_reg[33]) - $signed(dot_value_bank[bf_bank][23]);
        signal_vector[76] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[78] <= $signed(signal_reg[29]) - $signed(dot_value_bank[bf_bank][22]);
        signal_vector[78] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[80] <= $signed(signal_reg[25]) - $signed(dot_value_bank[bf_bank][21]);
        signal_vector[80] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[82] <= $signed(signal_reg[21]) - $signed(dot_value_bank[bf_bank][20]);
        signal_vector[82] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[84] <= $signed(signal_reg[17]) - $signed(dot_value_bank[bf_bank][19]);
        signal_vector[84] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[86] <= $signed(signal_reg[12]) - $signed(dot_value_bank[bf_bank][18]);
        signal_vector[86] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[88] <= $signed(signal_reg[7]) - $signed(dot_value_bank[bf_bank][17]);
        signal_vector[88] <= bf_vector_id;
    end
    if (bf_cycle == 6'd7) begin
        signal_reg[90] <= $signed(signal_reg[2]) - $signed(dot_value_bank[bf_bank][16]);
        signal_vector[90] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[37] <= $signed(signal_reg[36]) + $signed(dot_value_bank[bf_bank][24]);
        signal_vector[37] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[40] <= $signed(signal_reg[39]) + $signed(dot_value_bank[bf_bank][25]);
        signal_vector[40] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[43] <= $signed(signal_reg[42]) + $signed(dot_value_bank[bf_bank][26]);
        signal_vector[43] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[46] <= $signed(signal_reg[45]) + $signed(dot_value_bank[bf_bank][27]);
        signal_vector[46] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[49] <= $signed(signal_reg[48]) + $signed(dot_value_bank[bf_bank][28]);
        signal_vector[49] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[52] <= $signed(signal_reg[51]) + $signed(dot_value_bank[bf_bank][29]);
        signal_vector[52] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[55] <= $signed(signal_reg[54]) + $signed(dot_value_bank[bf_bank][30]);
        signal_vector[55] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[58] <= $signed(signal_reg[57]) + $signed(dot_value_bank[bf_bank][31]);
        signal_vector[58] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[60] <= $signed(signal_reg[57]) - $signed(dot_value_bank[bf_bank][31]);
        signal_vector[60] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[62] <= $signed(signal_reg[54]) - $signed(dot_value_bank[bf_bank][30]);
        signal_vector[62] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[64] <= $signed(signal_reg[51]) - $signed(dot_value_bank[bf_bank][29]);
        signal_vector[64] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[66] <= $signed(signal_reg[48]) - $signed(dot_value_bank[bf_bank][28]);
        signal_vector[66] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[68] <= $signed(signal_reg[45]) - $signed(dot_value_bank[bf_bank][27]);
        signal_vector[68] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[70] <= $signed(signal_reg[42]) - $signed(dot_value_bank[bf_bank][26]);
        signal_vector[70] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[72] <= $signed(signal_reg[39]) - $signed(dot_value_bank[bf_bank][25]);
        signal_vector[72] <= bf_vector_id;
    end
    if (bf_cycle == 6'd8) begin
        signal_reg[74] <= $signed(signal_reg[36]) - $signed(dot_value_bank[bf_bank][24]);
        signal_vector[74] <= bf_vector_id;
    end
    if (bf_cycle == 6'd10) begin
        signal_reg[4] <= $signed(signal_reg[3]) + $signed(dot_value_bank[bf_bank][32]);
        signal_vector[4] <= bf_vector_id;
    end
    if (bf_cycle == 6'd10) begin
        signal_reg[9] <= $signed(signal_reg[8]) + $signed(dot_value_bank[bf_bank][33]);
        signal_vector[9] <= bf_vector_id;
    end
    if (bf_cycle == 6'd10) begin
        signal_reg[14] <= $signed(signal_reg[13]) + $signed(dot_value_bank[bf_bank][34]);
        signal_vector[14] <= bf_vector_id;
    end
    if (bf_cycle == 6'd10) begin
        signal_reg[19] <= $signed(signal_reg[18]) + $signed(dot_value_bank[bf_bank][35]);
        signal_vector[19] <= bf_vector_id;
    end
    if (bf_cycle == 6'd10) begin
        signal_reg[120] <= $signed(signal_reg[18]) - $signed(dot_value_bank[bf_bank][35]);
        signal_vector[120] <= bf_vector_id;
    end
    if (bf_cycle == 6'd10) begin
        signal_reg[121] <= $signed(signal_reg[13]) - $signed(dot_value_bank[bf_bank][34]);
        signal_vector[121] <= bf_vector_id;
    end
    if (bf_cycle == 6'd10) begin
        signal_reg[122] <= $signed(signal_reg[8]) - $signed(dot_value_bank[bf_bank][33]);
        signal_vector[122] <= bf_vector_id;
    end
    if (bf_cycle == 6'd10) begin
        signal_reg[123] <= $signed(signal_reg[3]) - $signed(dot_value_bank[bf_bank][32]);
        signal_vector[123] <= bf_vector_id;
    end
    if (bf_cycle == 6'd11) begin
        signal_reg[23] <= $signed(signal_reg[22]) + $signed(dot_value_bank[bf_bank][36]);
        signal_vector[23] <= bf_vector_id;
    end
    if (bf_cycle == 6'd11) begin
        signal_reg[27] <= $signed(signal_reg[26]) + $signed(dot_value_bank[bf_bank][37]);
        signal_vector[27] <= bf_vector_id;
    end
    if (bf_cycle == 6'd11) begin
        signal_reg[31] <= $signed(signal_reg[30]) + $signed(dot_value_bank[bf_bank][38]);
        signal_vector[31] <= bf_vector_id;
    end
    if (bf_cycle == 6'd11) begin
        signal_reg[35] <= $signed(signal_reg[34]) + $signed(dot_value_bank[bf_bank][39]);
        signal_vector[35] <= bf_vector_id;
    end
    if (bf_cycle == 6'd11) begin
        signal_reg[116] <= $signed(signal_reg[34]) - $signed(dot_value_bank[bf_bank][39]);
        signal_vector[116] <= bf_vector_id;
    end
    if (bf_cycle == 6'd11) begin
        signal_reg[117] <= $signed(signal_reg[30]) - $signed(dot_value_bank[bf_bank][38]);
        signal_vector[117] <= bf_vector_id;
    end
    if (bf_cycle == 6'd11) begin
        signal_reg[118] <= $signed(signal_reg[26]) - $signed(dot_value_bank[bf_bank][37]);
        signal_vector[118] <= bf_vector_id;
    end
    if (bf_cycle == 6'd11) begin
        signal_reg[119] <= $signed(signal_reg[22]) - $signed(dot_value_bank[bf_bank][36]);
        signal_vector[119] <= bf_vector_id;
    end
    if (bf_cycle == 6'd12) begin
        signal_reg[38] <= $signed(signal_reg[37]) + $signed(dot_value_bank[bf_bank][40]);
        signal_vector[38] <= bf_vector_id;
    end
    if (bf_cycle == 6'd12) begin
        signal_reg[41] <= $signed(signal_reg[40]) + $signed(dot_value_bank[bf_bank][41]);
        signal_vector[41] <= bf_vector_id;
    end
    if (bf_cycle == 6'd12) begin
        signal_reg[44] <= $signed(signal_reg[43]) + $signed(dot_value_bank[bf_bank][42]);
        signal_vector[44] <= bf_vector_id;
    end
    if (bf_cycle == 6'd12) begin
        signal_reg[47] <= $signed(signal_reg[46]) + $signed(dot_value_bank[bf_bank][43]);
        signal_vector[47] <= bf_vector_id;
    end
    if (bf_cycle == 6'd12) begin
        signal_reg[112] <= $signed(signal_reg[46]) - $signed(dot_value_bank[bf_bank][43]);
        signal_vector[112] <= bf_vector_id;
    end
    if (bf_cycle == 6'd12) begin
        signal_reg[113] <= $signed(signal_reg[43]) - $signed(dot_value_bank[bf_bank][42]);
        signal_vector[113] <= bf_vector_id;
    end
    if (bf_cycle == 6'd12) begin
        signal_reg[114] <= $signed(signal_reg[40]) - $signed(dot_value_bank[bf_bank][41]);
        signal_vector[114] <= bf_vector_id;
    end
    if (bf_cycle == 6'd12) begin
        signal_reg[115] <= $signed(signal_reg[37]) - $signed(dot_value_bank[bf_bank][40]);
        signal_vector[115] <= bf_vector_id;
    end
    if (bf_cycle == 6'd13) begin
        signal_reg[50] <= $signed(signal_reg[49]) + $signed(dot_value_bank[bf_bank][44]);
        signal_vector[50] <= bf_vector_id;
    end
    if (bf_cycle == 6'd13) begin
        signal_reg[53] <= $signed(signal_reg[52]) + $signed(dot_value_bank[bf_bank][45]);
        signal_vector[53] <= bf_vector_id;
    end
    if (bf_cycle == 6'd13) begin
        signal_reg[56] <= $signed(signal_reg[55]) + $signed(dot_value_bank[bf_bank][46]);
        signal_vector[56] <= bf_vector_id;
    end
    if (bf_cycle == 6'd13) begin
        signal_reg[59] <= $signed(signal_reg[58]) + $signed(dot_value_bank[bf_bank][47]);
        signal_vector[59] <= bf_vector_id;
    end
    if (bf_cycle == 6'd13) begin
        signal_reg[108] <= $signed(signal_reg[58]) - $signed(dot_value_bank[bf_bank][47]);
        signal_vector[108] <= bf_vector_id;
    end
    if (bf_cycle == 6'd13) begin
        signal_reg[109] <= $signed(signal_reg[55]) - $signed(dot_value_bank[bf_bank][46]);
        signal_vector[109] <= bf_vector_id;
    end
    if (bf_cycle == 6'd13) begin
        signal_reg[110] <= $signed(signal_reg[52]) - $signed(dot_value_bank[bf_bank][45]);
        signal_vector[110] <= bf_vector_id;
    end
    if (bf_cycle == 6'd13) begin
        signal_reg[111] <= $signed(signal_reg[49]) - $signed(dot_value_bank[bf_bank][44]);
        signal_vector[111] <= bf_vector_id;
    end
    if (bf_cycle == 6'd14) begin
        signal_reg[61] <= $signed(signal_reg[60]) + $signed(dot_value_bank[bf_bank][48]);
        signal_vector[61] <= bf_vector_id;
    end
    if (bf_cycle == 6'd14) begin
        signal_reg[63] <= $signed(signal_reg[62]) + $signed(dot_value_bank[bf_bank][49]);
        signal_vector[63] <= bf_vector_id;
    end
    if (bf_cycle == 6'd14) begin
        signal_reg[65] <= $signed(signal_reg[64]) + $signed(dot_value_bank[bf_bank][50]);
        signal_vector[65] <= bf_vector_id;
    end
    if (bf_cycle == 6'd14) begin
        signal_reg[67] <= $signed(signal_reg[66]) + $signed(dot_value_bank[bf_bank][51]);
        signal_vector[67] <= bf_vector_id;
    end
    if (bf_cycle == 6'd14) begin
        signal_reg[104] <= $signed(signal_reg[66]) - $signed(dot_value_bank[bf_bank][51]);
        signal_vector[104] <= bf_vector_id;
    end
    if (bf_cycle == 6'd14) begin
        signal_reg[105] <= $signed(signal_reg[64]) - $signed(dot_value_bank[bf_bank][50]);
        signal_vector[105] <= bf_vector_id;
    end
    if (bf_cycle == 6'd14) begin
        signal_reg[106] <= $signed(signal_reg[62]) - $signed(dot_value_bank[bf_bank][49]);
        signal_vector[106] <= bf_vector_id;
    end
    if (bf_cycle == 6'd14) begin
        signal_reg[107] <= $signed(signal_reg[60]) - $signed(dot_value_bank[bf_bank][48]);
        signal_vector[107] <= bf_vector_id;
    end
    if (bf_cycle == 6'd15) begin
        signal_reg[69] <= $signed(signal_reg[68]) + $signed(dot_value_bank[bf_bank][52]);
        signal_vector[69] <= bf_vector_id;
    end
    if (bf_cycle == 6'd15) begin
        signal_reg[71] <= $signed(signal_reg[70]) + $signed(dot_value_bank[bf_bank][53]);
        signal_vector[71] <= bf_vector_id;
    end
    if (bf_cycle == 6'd15) begin
        signal_reg[73] <= $signed(signal_reg[72]) + $signed(dot_value_bank[bf_bank][54]);
        signal_vector[73] <= bf_vector_id;
    end
    if (bf_cycle == 6'd15) begin
        signal_reg[75] <= $signed(signal_reg[74]) + $signed(dot_value_bank[bf_bank][55]);
        signal_vector[75] <= bf_vector_id;
    end
    if (bf_cycle == 6'd15) begin
        signal_reg[100] <= $signed(signal_reg[74]) - $signed(dot_value_bank[bf_bank][55]);
        signal_vector[100] <= bf_vector_id;
    end
    if (bf_cycle == 6'd15) begin
        signal_reg[101] <= $signed(signal_reg[72]) - $signed(dot_value_bank[bf_bank][54]);
        signal_vector[101] <= bf_vector_id;
    end
    if (bf_cycle == 6'd15) begin
        signal_reg[102] <= $signed(signal_reg[70]) - $signed(dot_value_bank[bf_bank][53]);
        signal_vector[102] <= bf_vector_id;
    end
    if (bf_cycle == 6'd15) begin
        signal_reg[103] <= $signed(signal_reg[68]) - $signed(dot_value_bank[bf_bank][52]);
        signal_vector[103] <= bf_vector_id;
    end
    if (bf_cycle == 6'd16) begin
        signal_reg[77] <= $signed(signal_reg[76]) + $signed(dot_value_bank[bf_bank][56]);
        signal_vector[77] <= bf_vector_id;
    end
    if (bf_cycle == 6'd16) begin
        signal_reg[79] <= $signed(signal_reg[78]) + $signed(dot_value_bank[bf_bank][57]);
        signal_vector[79] <= bf_vector_id;
    end
    if (bf_cycle == 6'd16) begin
        signal_reg[81] <= $signed(signal_reg[80]) + $signed(dot_value_bank[bf_bank][58]);
        signal_vector[81] <= bf_vector_id;
    end
    if (bf_cycle == 6'd16) begin
        signal_reg[83] <= $signed(signal_reg[82]) + $signed(dot_value_bank[bf_bank][59]);
        signal_vector[83] <= bf_vector_id;
    end
    if (bf_cycle == 6'd16) begin
        signal_reg[96] <= $signed(signal_reg[82]) - $signed(dot_value_bank[bf_bank][59]);
        signal_vector[96] <= bf_vector_id;
    end
    if (bf_cycle == 6'd16) begin
        signal_reg[97] <= $signed(signal_reg[80]) - $signed(dot_value_bank[bf_bank][58]);
        signal_vector[97] <= bf_vector_id;
    end
    if (bf_cycle == 6'd16) begin
        signal_reg[98] <= $signed(signal_reg[78]) - $signed(dot_value_bank[bf_bank][57]);
        signal_vector[98] <= bf_vector_id;
    end
    if (bf_cycle == 6'd16) begin
        signal_reg[99] <= $signed(signal_reg[76]) - $signed(dot_value_bank[bf_bank][56]);
        signal_vector[99] <= bf_vector_id;
    end
    if (bf_cycle == 6'd17) begin
        signal_reg[85] <= $signed(signal_reg[84]) + $signed(dot_value_bank[bf_bank][60]);
        signal_vector[85] <= bf_vector_id;
    end
    if (bf_cycle == 6'd17) begin
        signal_reg[87] <= $signed(signal_reg[86]) + $signed(dot_value_bank[bf_bank][61]);
        signal_vector[87] <= bf_vector_id;
    end
    if (bf_cycle == 6'd17) begin
        signal_reg[89] <= $signed(signal_reg[88]) + $signed(dot_value_bank[bf_bank][62]);
        signal_vector[89] <= bf_vector_id;
    end
    if (bf_cycle == 6'd17) begin
        signal_reg[91] <= $signed(signal_reg[90]) + $signed(dot_value_bank[bf_bank][63]);
        signal_vector[91] <= bf_vector_id;
    end
    if (bf_cycle == 6'd17) begin
        signal_reg[92] <= $signed(signal_reg[90]) - $signed(dot_value_bank[bf_bank][63]);
        signal_vector[92] <= bf_vector_id;
    end
    if (bf_cycle == 6'd17) begin
        signal_reg[93] <= $signed(signal_reg[88]) - $signed(dot_value_bank[bf_bank][62]);
        signal_vector[93] <= bf_vector_id;
    end
    if (bf_cycle == 6'd17) begin
        signal_reg[94] <= $signed(signal_reg[86]) - $signed(dot_value_bank[bf_bank][61]);
        signal_vector[94] <= bf_vector_id;
    end
    if (bf_cycle == 6'd17) begin
        signal_reg[95] <= $signed(signal_reg[84]) - $signed(dot_value_bank[bf_bank][60]);
        signal_vector[95] <= bf_vector_id;
    end
end
// R4B_EVENT_STATIC_END
