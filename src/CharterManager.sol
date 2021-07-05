// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2021 Dai Foundation
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.6.12;

interface VatLike {
    function live() external view returns (uint256);
    function urns(bytes32, address) external view returns (uint256, uint256);
    function dai(address) external view returns (uint256);
    function fork(bytes32, address, address, int256, int256) external;
    function frob(bytes32, address, address, address, int256, int256) external;
    function flux(bytes32, address, address, uint256) external;
    function move(address, address, uint256) external;
    function hope(address) external;
    function nope(address) external;
    function ilks(bytes32) external view returns (
        uint256 Art,  // [wad]
        uint256 rate, // [ray]
        uint256 spot, // [ray]
        uint256 line, // [rad]
        uint256 dust  // [rad]
    );
}

interface AuthGemJoinLike {
    function gem() external view returns (address);
    function ilk() external view returns (bytes32);
    function join(address, address, uint256) external;
    function exit(address, address, uint256) external;
}

interface TokenLike {
    function approve(address, uint256) external;
    function transferFrom(address, address, uint256) external;
}

contract UrnProxy {
    address immutable public usr;

    constructor(address vat_, address usr_) public {
        usr = usr_;
        VatLike(vat_).hope(msg.sender);
    }
}

contract CharterManager {
    mapping (address => uint256) public wards;
    mapping (address => address) public proxy;  // UrnProxy per user
    address public implementation;

    event Rely(address indexed);
    event Deny(address indexed);
    event SetImplementation(address indexed);

    constructor() public {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    function rely(address usr) public auth { wards[usr] = 1; emit Rely(msg.sender); }
    function deny(address usr) public auth { wards[usr] = 0; emit Deny(msg.sender); }
    modifier auth { require(wards[msg.sender] == 1, "CharterManager/non-authed"); _; }

    function setImplementation(address implementation_) external auth {
        implementation = implementation_;
        emit SetImplementation(implementation_);
    }

    fallback() external {
        address _impl = implementation;
        require(_impl != address(0));

        assembly {
            let ptr := mload(0x40)
            calldatacopy(ptr, 0, calldatasize())
            let result := delegatecall(gas(), _impl, ptr, calldatasize(), 0, 0)
            let size := returndatasize()
            returndatacopy(ptr, 0, size)

            switch result
            case 0 { revert(ptr, size) }
            default { return(ptr, size) }
        }
    }
}

contract CharterManagerImp {
    // --- Data ---
    bytes32 slot0;
    mapping (address => address) proxy;  // UrnProxy per user
    bytes32 slot2;

    address public immutable vat;
    address public immutable vow;

    mapping (address => uint256) public wards;
    mapping (bytes32 => mapping(address => uint256)) public line; // line per ilk per user
    mapping (bytes32 => mapping(address => uint256)) public nib;  // nib per ilk per user

    // --- Administration ---
    function file(bytes32 ilk, address user, bytes32 what, uint256 data) external auth {
        if (what == "line") line[ilk][user] = data;
        else if (what == "nib") nib[ilk][user] = data;
        else revert("CharterManager/file-unrecognized-param");
    }

    // --- Math ---
    uint256 constant WAD = 10 ** 18;

    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    function wmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = mul(x, y) / WAD;
    }

    // --- Auth ---
    event Rely(address indexed);
    event Deny(address indexed);
    function rely(address usr) public auth { wards[usr] = 1; emit Rely(msg.sender); }
    function deny(address usr) public auth { wards[usr] = 0; emit Deny(msg.sender); }
    modifier auth { require(wards[msg.sender] == 1, "CharterManager/non-authed"); _; }

    constructor(address vat_, address vow_) public {
        vat = vat_;
        vow = vow_;
        wards[msg.sender] = 1;
    }

    function getOrCreateProxy(address usr) public returns (address urp) {
        urp = proxy[usr];
        if (urp == address(0)) {
            urp = proxy[usr] = address(new UrnProxy(address(vat), usr));
        }
    }

    function join(address gemJoin, address usr, uint256 val) external {
        TokenLike(AuthGemJoinLike(gemJoin).gem()).transferFrom(msg.sender, address(this), val);
        TokenLike(AuthGemJoinLike(gemJoin).gem()).approve(gemJoin, val);
        AuthGemJoinLike(gemJoin).join(getOrCreateProxy(usr), usr, val);
    }

    function exit(address gemJoin, address usr, uint256 val) external {
        address urp = proxy[msg.sender];
        require(urp != address(0), "CharterManager/non-existing-urp");
        AuthGemJoinLike(gemJoin).exit(urp, usr, val);
    }

    function frob(address gemJoin, address u, address v, address w, int256 dink, int256 dart) external {
        require(u == msg.sender && v == msg.sender && w == msg.sender, "CharterManager/not-allowed");

        // Note: This simplification only works because of the u == v == msg.sender restriction above
        address urp = getOrCreateProxy(u);
        bytes32 ilk = AuthGemJoinLike(gemJoin).ilk();
        VatLike(vat).frob(ilk, urp, urp, w, dink, dart);

        if (dart > 0) {
            (,uint256 rate,,,) = VatLike(vat).ilks(ilk);
            (, uint256 art) = VatLike(vat).urns(ilk, urp);
            require(mul(art, rate) <= line[ilk][u], "CharterManager/user-line-exceeded");

            uint dtab = mul(rate, uint256(dart)); // rad
            uint256 coin = wmul(dtab, nib[ilk][u]); // rad
            VatLike(vat).move(urp, vow, coin);
        }
    }

    function flux(address gemJoin, address src, address dst, uint256 wad) external {
        require(src == msg.sender, "CharterManager/not-allowed");

        address surp = getOrCreateProxy(src);
        address durp = getOrCreateProxy(dst);

        VatLike(vat).flux(AuthGemJoinLike(gemJoin).ilk(), surp, durp, wad);
    }

    function quit(bytes32 ilk, address dst) external {
        require(VatLike(vat).live() == 0, "CharterManager/vat-still-live");

        address urp = getOrCreateProxy(msg.sender);
        (uint256 ink, uint256 art) = VatLike(vat).urns(ilk, urp);
        require(int256(ink) >= 0, "CharterManager/overflow");
        require(int256(art) >= 0, "CharterManager/overflow");
        VatLike(vat).fork(
            ilk,
            urp,
            dst,
            int256(ink),
            int256(art)
        );
    }
}
